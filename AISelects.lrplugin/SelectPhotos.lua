--[[
  SelectPhotos.lua
  ─────────────────────────────────────────────────────────────────────────────
  Pass 2: Reads AI scores from custom metadata, applies selection pipeline,
  and creates a Collection with the final selects.

  Two selection modes:
    Best Of — quality-driven culling with temporal distribution
    Story   — AI-driven narrative selection with presets and gap detection

  Both modes share: reject → burst dedup → phash dedup → face coverage.
  They diverge at the final selection step.

  Can be invoked directly (as a menu item) or via ScoreAndSelect.lua
  which calls the exported runSelection(context, overrides) function.

  macOS only. Settings via Library > Plugin Extras > Settings...
--]]

-- ── LR SDK imports ─────────────────────────────────────────────────────────
local LrApplication     = import 'LrApplication'
local LrDate            = import 'LrDate'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils       = import 'LrPathUtils'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'

local json   = dofile(_PLUGIN.path .. '/dkjson.lua')
local Prefs  = dofile(_PLUGIN.path .. '/Prefs.lua')
local Engine = dofile(_PLUGIN.path .. '/AIEngine.lua')

-- ── Read scores from custom metadata ────────────────────────────────────
local function readScores(photo)
    local technical  = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsTechnical'))
    local aesthetic  = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsAesthetic'))
    local content    = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsContent')
    local category   = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsCategory')
    local rejectStr  = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsReject')
    local scoreDate  = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate')

    if not technical or not scoreDate or scoreDate == "" then
        return nil  -- not scored
    end

    local phash         = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsPhash')
    local narrativeRole = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsNarrativeRole')
    local eyeQuality    = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsEyeQuality')

    return {
        photo         = photo,
        technical     = technical,
        aesthetic     = aesthetic or 5,
        content       = content or "unknown",
        category      = category or "other",
        narrativeRole = narrativeRole or "detail",
        eyeQuality    = eyeQuality or "na",
        reject        = (rejectStr == "true"),
        phash         = phash,
        scoreDate     = scoreDate,
    }
end

-- ── Deduplicate by EXIF timestamp ───────────────────────────────────────
-- Groups photos taken within burstThresholdSecs of each other.
-- Within each group, keeps only the highest-scoring photo.
local function deduplicateByTimestamp(entries, burstThresholdSecs)
    if #entries == 0 then return entries end

    -- Read timestamps
    for _, e in ipairs(entries) do
        e.timestamp = e.photo:getRawMetadata('dateTimeOriginal')
    end

    -- Sort by timestamp (nil timestamps go to end)
    table.sort(entries, function(a, b)
        if not a.timestamp then return false end
        if not b.timestamp then return true end
        return a.timestamp < b.timestamp
    end)

    -- Walk sorted list, group adjacent photos within threshold.
    -- Compare to the group anchor (first photo of the burst), not the previous photo.
    -- This prevents the "chain effect" where a slow continuous stream of photos
    -- 1.5s apart (within a 2s threshold) all chain into one mega-burst.
    local result = {}
    local groupBest  = entries[1]
    local groupStart = entries[1]  -- anchor: first photo of the current burst

    for i = 2, #entries do
        local curr = entries[i]

        local inBurst = false
        if curr.timestamp and groupStart.timestamp then
            local diff = math.abs(curr.timestamp - groupStart.timestamp)
            if diff <= burstThresholdSecs then
                inBurst = true
            end
        end

        if inBurst then
            if curr.compositeScore > groupBest.compositeScore then
                groupBest = curr
            end
        else
            table.insert(result, groupBest)
            groupBest  = curr
            groupStart = curr  -- new burst starts here
        end
    end
    table.insert(result, groupBest)

    return result
end

-- ── Deduplicate by perceptual hash ──────────────────────────────────────
local PHASH_THRESHOLD = 10  -- out of 64 bits; <10 is very similar

local function deduplicateByPhash(entries)
    if #entries < 2 then return entries, 0 end

    local sorted = {}
    for _, e in ipairs(entries) do table.insert(sorted, e) end
    table.sort(sorted, function(a, b)
        return a.compositeScore > b.compositeScore
    end)

    local kept = {}
    local removed = 0

    for _, candidate in ipairs(sorted) do
        local dominated = false
        if candidate.phash then
            for _, keeper in ipairs(kept) do
                if keeper.phash then
                    local dist = Engine.hashDistance(candidate.phash, keeper.phash)
                    if dist < PHASH_THRESHOLD then
                        dominated = true
                        break
                    end
                end
            end
        end
        if not dominated then
            table.insert(kept, candidate)
        else
            removed = removed + 1
        end
    end

    return kept, removed
end

-- ── Group by category ──────────────────────────────────────────────────
local function groupByCategory(entries)
    local groups = {}
    local groupOrder = {}

    for _, e in ipairs(entries) do
        local cat = e.category
        if not groups[cat] then
            groups[cat] = {}
            table.insert(groupOrder, cat)
        end
        table.insert(groups[cat], e)
    end

    for _, cat in ipairs(groupOrder) do
        table.sort(groups[cat], function(a, b)
            return a.compositeScore > b.compositeScore
        end)
    end

    return groups, groupOrder
end

-- ── Distribute target count across groups ──────────────────────────────
local function distributeTarget(groups, groupOrder, targetCount, varietyMode, totalAvailable)
    local selected = {}
    local selectedSet = {}

    if varietyMode == "equal" then
        local perGroup = math.floor(targetCount / #groupOrder)
        local remainder = targetCount - (perGroup * #groupOrder)

        for idx, cat in ipairs(groupOrder) do
            local slots = perGroup
            if idx <= remainder then slots = slots + 1 end
            for j = 1, math.min(slots, #groups[cat]) do
                local e = groups[cat][j]
                if not selectedSet[e.photo] then
                    table.insert(selected, e)
                    selectedSet[e.photo] = true
                end
            end
        end
    else
        for _, cat in ipairs(groupOrder) do
            local proportion = #groups[cat] / totalAvailable
            local slots = math.max(1, math.floor(targetCount * proportion))
            for j = 1, math.min(slots, #groups[cat]) do
                local e = groups[cat][j]
                if not selectedSet[e.photo] then
                    table.insert(selected, e)
                    selectedSet[e.photo] = true
                end
            end
        end
    end

    -- Fill remaining slots with highest-scoring unselected photos
    if #selected < targetCount then
        local remaining = {}
        for _, cat in ipairs(groupOrder) do
            for _, e in ipairs(groups[cat]) do
                if not selectedSet[e.photo] then
                    table.insert(remaining, e)
                end
            end
        end
        table.sort(remaining, function(a, b)
            return a.compositeScore > b.compositeScore
        end)

        for _, e in ipairs(remaining) do
            if #selected >= targetCount then break end
            table.insert(selected, e)
            selectedSet[e.photo] = true
        end
    end

    return selected
end

-- ── Face coverage guarantee ──────────────────────────────────────────────
-- Ensures at least one photo of every named person is in the selection.
-- Returns (faceAddedCount, allPeopleNames)
local function ensureFaceCoverage(selected, pool, catalog)
    local faceAddedCount = 0
    local allPeopleNames = {}

    local faceQueryOk, _ = LrTasks.pcall(function()
        local poolPhotos = {}
        for _, e in ipairs(pool) do
            table.insert(poolPhotos, e.photo)
        end

        local faceMap = Engine.queryFacePeople(catalog, poolPhotos)

        -- Build set of all named people and their best photos
        local allPeople = {}
        local peopleBestPhoto = {}
        for _, e in ipairs(pool) do
            local names = faceMap[e.photo.localIdentifier]
            if names then
                for _, name in ipairs(names) do
                    if not allPeople[name] then
                        allPeople[name] = true
                        table.insert(allPeopleNames, name)
                    end
                    if not peopleBestPhoto[name] or e.compositeScore > peopleBestPhoto[name].compositeScore then
                        peopleBestPhoto[name] = e
                    end
                end
            end
        end

        -- Check which people are already covered
        local selectedSet = {}
        for _, e in ipairs(selected) do selectedSet[e.photo] = true end

        local coveredPeople = {}
        for _, e in ipairs(selected) do
            local names = faceMap[e.photo.localIdentifier]
            if names then
                for _, name in ipairs(names) do
                    coveredPeople[name] = true
                end
            end
        end

        -- Add missing people's best photos
        for name, _ in pairs(allPeople) do
            if not coveredPeople[name] and peopleBestPhoto[name] then
                local e = peopleBestPhoto[name]
                if not selectedSet[e.photo] then
                    table.insert(selected, e)
                    selectedSet[e.photo] = true
                    faceAddedCount = faceAddedCount + 1
                    local names2 = faceMap[e.photo.localIdentifier]
                    if names2 then
                        for _, n in ipairs(names2) do
                            coveredPeople[n] = true
                        end
                    end
                end
            end
        end
    end)

    return faceAddedCount, allPeopleNames
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MODE 1: BEST OF — quality-driven culling with temporal distribution
-- ═══════════════════════════════════════════════════════════════════════════

local function selectBestOf(pool, settings)
    local targetCount = math.min(settings.targetCount, #pool)

    -- Temporal distribution: divide timeline into segments, allocate proportionally
    -- This prevents early-photo clustering

    -- Separate dated from undated photos
    local dated = {}
    local undated = {}
    for _, e in ipairs(pool) do
        if e.timestamp then
            table.insert(dated, e)
        else
            table.insert(undated, e)
        end
    end

    -- If few dated photos or small target, skip temporal distribution
    local numSegments = math.max(4, math.floor(targetCount / 10))
    if #dated < numSegments * 2 or targetCount <= 10 then
        -- Fall back to simple category distribution (original behavior)
        local groups, groupOrder = groupByCategory(pool)
        return distributeTarget(groups, groupOrder, targetCount, settings.varietyMode, #pool), groupOrder
    end

    -- Sort dated by timestamp
    table.sort(dated, function(a, b) return a.timestamp < b.timestamp end)

    -- Divide into equal time-span segments
    local minTime = dated[1].timestamp
    local maxTime = dated[#dated].timestamp
    local timeSpan = maxTime - minTime

    if timeSpan <= 0 then
        -- All photos have the same timestamp — skip temporal distribution
        local groups, groupOrder = groupByCategory(pool)
        return distributeTarget(groups, groupOrder, targetCount, settings.varietyMode, #pool), groupOrder
    end

    local segmentDuration = timeSpan / numSegments
    local segments = {}
    for s = 1, numSegments do segments[s] = {} end

    for _, e in ipairs(dated) do
        local segIdx = math.min(numSegments, math.floor((e.timestamp - minTime) / segmentDuration) + 1)
        table.insert(segments[segIdx], e)
    end

    -- Allocate target count to segments proportionally, then distribute within each
    local selected = {}
    local selectedSet = {}
    local allGroupOrder = {}
    local allGroupOrderSet = {}

    -- Reserve a portion for undated photos
    local undatedTarget = 0
    if #undated > 0 then
        undatedTarget = math.max(1, math.floor(targetCount * #undated / #pool))
    end
    local datedTarget = targetCount - undatedTarget

    for s = 1, numSegments do
        if #segments[s] > 0 then
            local segTarget = math.max(1, math.ceil(datedTarget * #segments[s] / #dated))
            local groups, groupOrder = groupByCategory(segments[s])
            local segSelected = distributeTarget(groups, groupOrder, segTarget, settings.varietyMode, #segments[s])
            for _, e in ipairs(segSelected) do
                if not selectedSet[e.photo] then
                    table.insert(selected, e)
                    selectedSet[e.photo] = true
                end
            end
            for _, cat in ipairs(groupOrder) do
                if not allGroupOrderSet[cat] then
                    table.insert(allGroupOrder, cat)
                    allGroupOrderSet[cat] = true
                end
            end
        end
    end

    -- Handle undated photos
    if #undated > 0 and undatedTarget > 0 then
        local groups, groupOrder = groupByCategory(undated)
        local undatedSelected = distributeTarget(groups, groupOrder, undatedTarget, settings.varietyMode, #undated)
        for _, e in ipairs(undatedSelected) do
            if not selectedSet[e.photo] then
                table.insert(selected, e)
                selectedSet[e.photo] = true
            end
        end
        for _, cat in ipairs(groupOrder) do
            if not allGroupOrderSet[cat] then
                table.insert(allGroupOrder, cat)
                allGroupOrderSet[cat] = true
            end
        end
    end

    -- Trim to target count (segments may slightly overshoot)
    if #selected > targetCount then
        -- Sort by composite score, keep top targetCount
        table.sort(selected, function(a, b)
            return a.compositeScore > b.compositeScore
        end)
        local trimmed = {}
        for i = 1, targetCount do
            trimmed[i] = selected[i]
        end
        selected = trimmed
    end

    -- Fill remaining slots with highest-scoring unselected across all segments
    if #selected < targetCount then
        selectedSet = {}
        for _, e in ipairs(selected) do selectedSet[e.photo] = true end

        local remaining = {}
        for _, e in ipairs(pool) do
            if not selectedSet[e.photo] then
                table.insert(remaining, e)
            end
        end
        table.sort(remaining, function(a, b)
            return a.compositeScore > b.compositeScore
        end)
        for _, e in ipairs(remaining) do
            if #selected >= targetCount then break end
            table.insert(selected, e)
        end
    end

    return selected, allGroupOrder
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MODE 2: STORY — AI-driven narrative selection
-- ═══════════════════════════════════════════════════════════════════════════

local function buildMetadataSummary(entries, faceMap)
    local items = {}
    for _, e in ipairs(entries) do
        local ts = nil
        if e.timestamp then
            ts = LrDate.timeToUserFormat(e.timestamp, "%Y-%m-%d %H:%M:%S")
        end
        local item = {
            id             = e.photo.localIdentifier,
            technical      = e.technical,
            aesthetic      = e.aesthetic,
            composite      = math.floor(e.compositeScore * 100 + 0.5) / 100,
            content        = e.content,
            category       = e.category,
            narrative_role = e.narrativeRole,
            eye_quality    = e.eyeQuality,
            timestamp      = ts,
            people         = faceMap[e.photo.localIdentifier] or {},
        }
        table.insert(items, item)
    end
    return items
end

local function selectStory(pool, settings, catalog)
    local targetCount = math.min(settings.targetCount, #pool)

    -- Load story presets
    local StoryPresets = dofile(_PLUGIN.path .. '/StoryPresets.lua')
    local preset = StoryPresets.getPreset(settings.storyPreset)

    -- Build face map for all pool photos
    local faceMap = {}
    local faceQueryOk, _ = LrTasks.pcall(function()
        local poolPhotos = {}
        for _, e in ipairs(pool) do table.insert(poolPhotos, e.photo) end
        faceMap = Engine.queryFacePeople(catalog, poolPhotos)
    end)

    -- Build metadata summary
    local metadataItems = buildMetadataSummary(pool, faceMap)

    -- Context window check: pre-filter if metadata exceeds model's context limit.
    -- Cloud models handle large contexts; local Ollama models vary widely
    -- so we use a conservative 6K token limit to avoid silent truncation.
    local summaryJson = json.encode(metadataItems)
    local estimatedTokens = #summaryJson / 4
    local tokenLimits = {
        claude = 150000,
        openai = 100000,   -- GPT-4.1 has 1M context but 100K is practical
        gemini = 800000,   -- Gemini Flash has 1M context
    }
    local tokenLimit = tokenLimits[settings.provider] or 6000

    if estimatedTokens > tokenLimit then
        -- Pre-filter: sort by composite score, take top candidates that fit
        -- Start with 3x target and shrink until we fit
        local candidateCount = math.min(#pool, targetCount * 3)
        local sortedPool = {}
        for _, e in ipairs(pool) do table.insert(sortedPool, e) end
        table.sort(sortedPool, function(a, b)
            return a.compositeScore > b.compositeScore
        end)

        -- Shrink candidate pool until it fits the context window
        while candidateCount > targetCount do
            local filteredPool = {}
            for i = 1, candidateCount do
                table.insert(filteredPool, sortedPool[i])
            end
            metadataItems = buildMetadataSummary(filteredPool, faceMap)
            summaryJson = json.encode(metadataItems)
            estimatedTokens = #summaryJson / 4
            if estimatedTokens <= tokenLimit then break end
            candidateCount = math.floor(candidateCount * 0.7)  -- shrink by 30%
        end

        -- If we still can't fit even targetCount photos, error out
        if estimatedTokens > tokenLimit and candidateCount <= targetCount then
            return nil, string.format(
                "Too many photos for this model's context window (%d photos, ~%dK tokens). " ..
                "Reduce the number of source photos or switch to a cloud provider (Claude, OpenAI, or Gemini).",
                #pool, math.floor(estimatedTokens / 1000))
        end
    end

    -- Build the prompt
    local guidelines = preset.guidelines or ""
    if settings.storyCustomInstructions and settings.storyCustomInstructions ~= "" then
        guidelines = guidelines .. "\n\nAdditional instructions from the photographer:\n" ..
            settings.storyCustomInstructions
    end

    local chronoConstraint = preset.chronological
        and "Maintain chronological order based on timestamps when available."
        or  "Order for visual flow and narrative impact; chronological order is not required."

    local peopleConstraint
    if preset.peopleEmphasis == "high" then
        peopleConstraint = "Prioritize photos with people. Ensure all named people appear at least once."
    elseif preset.peopleEmphasis == "low" then
        peopleConstraint = "People are not a priority. Focus on scenes, landscapes, and details."
    else
        peopleConstraint = "Balance people shots with environmental and detail shots."
    end

    local replacements = {
        ["%%PRESET_NAME%%"]              = preset.name or "Custom",
        ["%%GUIDELINES%%"]               = guidelines,
        ["%%CUSTOM_INSTRUCTIONS%%"]      = "",  -- already folded into guidelines
        ["%%TARGET_COUNT%%"]             = tostring(targetCount),
        ["%%CHRONOLOGICAL_CONSTRAINT%%"] = chronoConstraint,
        ["%%PEOPLE_CONSTRAINT%%"]        = peopleConstraint,
        ["%%METADATA_JSON%%"]            = summaryJson,
    }

    local prompt = Engine.STORY_PROMPT_TEMPLATE
    for placeholder, value in pairs(replacements) do
        prompt = prompt:gsub(placeholder, function() return value end)
    end

    -- AI call (text-only, no images)
    local response, queryErr
    if settings.provider == "claude" then
        response, queryErr = Engine.queryClaudeText(
            prompt, settings.claudeModel, settings.claudeApiKey, settings.timeoutSecs)
    elseif settings.provider == "openai" then
        response, queryErr = Engine.queryOpenAIText(
            prompt, settings.openaiModel, settings.openaiApiKey, settings.timeoutSecs)
    elseif settings.provider == "gemini" then
        response, queryErr = Engine.queryGeminiText(
            prompt, settings.geminiModel, settings.geminiApiKey, settings.timeoutSecs)
    else
        response, queryErr = Engine.queryOllamaText(
            prompt, settings.model, settings.ollamaUrl, settings.timeoutSecs)
    end

    if not response then
        return nil, "Story AI call failed: " .. tostring(queryErr)
    end

    -- Parse response
    local validIds = {}
    local entryById = {}
    for _, e in ipairs(pool) do
        table.insert(validIds, e.photo.localIdentifier)
        entryById[tostring(e.photo.localIdentifier)] = e
    end

    local storySelection, parseErr = Engine.parseStoryResponse(response, validIds)

    if not storySelection then
        -- Retry once with simplified prompt
        local retryPrompt = string.format(
            "Select exactly %d photos from this list and return them in narrative order.\n" ..
            "Return ONLY a JSON array of objects with: id (number), position (1 to %d), role (string), note (5-10 words).\n\n%s",
            targetCount, targetCount, summaryJson
        )

        local retryResp, retryErr
        if settings.provider == "claude" then
            retryResp, retryErr = Engine.queryClaudeText(
                retryPrompt, settings.claudeModel, settings.claudeApiKey, settings.timeoutSecs)
        elseif settings.provider == "openai" then
            retryResp, retryErr = Engine.queryOpenAIText(
                retryPrompt, settings.openaiModel, settings.openaiApiKey, settings.timeoutSecs)
        elseif settings.provider == "gemini" then
            retryResp, retryErr = Engine.queryGeminiText(
                retryPrompt, settings.geminiModel, settings.geminiApiKey, settings.timeoutSecs)
        else
            retryResp, retryErr = Engine.queryOllamaText(
                retryPrompt, settings.model, settings.ollamaUrl, settings.timeoutSecs)
        end

        if retryResp then
            storySelection, parseErr = Engine.parseStoryResponse(retryResp, validIds)
        end
    end

    if not storySelection then
        return nil, "Could not parse story response after retry: " .. tostring(parseErr)
    end

    -- Map back to entries, preserve AI ordering
    local selected = {}
    for _, item in ipairs(storySelection) do
        local e = entryById[item.id]
        if e then
            e.storyNote = item.story_note or ""
            e.storyPosition = item.position or #selected + 1
            table.insert(selected, e)
        end
    end

    -- Gap detection: check for missing required roles
    local coveredRoles = {}
    for _, e in ipairs(selected) do
        coveredRoles[e.storyRole or e.narrativeRole] = true
    end
    local gapsFilled = 0
    local selectedSet = {}
    for _, e in ipairs(selected) do selectedSet[e.photo] = true end

    if preset.requiredRoles then
        for _, role in ipairs(preset.requiredRoles) do
            if not coveredRoles[role] then
                -- Find best photo with this role from pool
                local best = nil
                for _, e in ipairs(pool) do
                    if not selectedSet[e.photo] and e.narrativeRole == role then
                        if not best or e.compositeScore > best.compositeScore then
                            best = e
                        end
                    end
                end
                if best then
                    best.storyNote = "Added to fill " .. role .. " gap"
                    best.storyRole = role
                    table.insert(selected, best)
                    selectedSet[best.photo] = true
                    gapsFilled = gapsFilled + 1
                end
            end
        end
    end

    -- Gap detection: timeline quartiles
    local datedPool = {}
    for _, e in ipairs(pool) do
        if e.timestamp then table.insert(datedPool, e) end
    end
    if #datedPool >= 4 then
        table.sort(datedPool, function(a, b) return a.timestamp < b.timestamp end)
        local minTime = datedPool[1].timestamp
        local maxTime = datedPool[#datedPool].timestamp
        local span = maxTime - minTime
        if span > 0 then
            local quartileDuration = span / 4
            for q = 1, 4 do
                local qStart = minTime + (q - 1) * quartileDuration
                local qEnd = minTime + q * quartileDuration
                local hasCoverage = false
                for _, e in ipairs(selected) do
                    if e.timestamp and e.timestamp >= qStart and e.timestamp <= qEnd then
                        hasCoverage = true
                        break
                    end
                end
                if not hasCoverage then
                    -- Find best photo from this quartile
                    local best = nil
                    for _, e in ipairs(datedPool) do
                        if e.timestamp >= qStart and e.timestamp <= qEnd and not selectedSet[e.photo] then
                            if not best or e.compositeScore > best.compositeScore then
                                best = e
                            end
                        end
                    end
                    if best then
                        best.storyNote = "Added for timeline coverage"
                        table.insert(selected, best)
                        selectedSet[best.photo] = true
                        gapsFilled = gapsFilled + 1
                    end
                end
            end
        end
    end

    return selected, nil, gapsFilled
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MAIN SELECTION PIPELINE
-- ═══════════════════════════════════════════════════════════════════════════

-- Core selection logic. Exported for ScoreAndSelect.lua.
-- overrides: optional table to override specific settings (from run dialog)
-- Returns summary string, or nil if no work done.
local function runSelection(context, overrides)
    local SETTINGS = Prefs.getPrefs()

    -- Apply overrides from run dialog (if provided by ScoreAndSelect.lua)
    if overrides then
        for k, v in pairs(overrides) do
            SETTINGS[k] = v
        end
    end

    local catalog      = LrApplication.activeCatalog()
    local targetPhotos = catalog:getTargetPhotos()

    if #targetPhotos == 0 then
        LrDialogs.message("AI Selects",
            "No photos selected.\n\nSelect one or more photos in the Library grid and try again.", "info")
        return nil
    end

    -- Progress scope for the selection phase
    local mode = SETTINGS.selectionMode or "bestof"
    local modeLabel = (mode == "story") and "Story" or "Best Of"
    local progress = LrProgressScope {
        title = "AI Selects — " .. modeLabel .. " selection",
        functionContext = context,
    }
    progress:setPortionComplete(0, 10)

    -- Read scores from all selected photos
    progress:setCaption("Reading scores...")
    local scored = {}
    local unscored = 0
    for _, photo in ipairs(targetPhotos) do
        local entry = readScores(photo)
        if entry then
            table.insert(scored, entry)
        else
            unscored = unscored + 1
        end
    end

    if #scored == 0 then
        progress:done()
        LrDialogs.message("AI Selects",
            "No scored photos found.\n\n" ..
            "Run 'Score Only' first to score your photos, then try again.", "warning")
        return nil
    end

    -- Compute composite scores (single pass, used by all downstream steps)
    -- Convert percentage to normalized weights (40% → 0.4 technical, 0.6 aesthetic)
    local techPct = SETTINGS.technicalPct or 40
    local qualityWeight   = techPct / 100
    local aestheticWeight = 1 - qualityWeight
    -- Eye quality: binary penalty — closed/squinting eyes are penalized, everything else neutral
    local EYE_PENALTY = -1.5
    for _, e in ipairs(scored) do
        local base = e.technical * qualityWeight + e.aesthetic * aestheticWeight
        local eyeAdj = (e.eyeQuality == "closed") and EYE_PENALTY or 0
        e.compositeScore = base + eyeAdj
    end

    local totalScored = #scored
    progress:setPortionComplete(1, 10)

    -- ── Shared pipeline: reject + dedup ───────────────────────────────────

    -- Step 1: Eliminate rejects
    progress:setCaption("Filtering rejects...")
    local afterReject = {}
    local rejectCount = 0
    for _, e in ipairs(scored) do
        if e.reject or e.technical < 3 then
            rejectCount = rejectCount + 1
        else
            table.insert(afterReject, e)
        end
    end

    -- Step 2a: Deduplicate by EXIF timestamp (burst detection)
    progress:setCaption("Removing burst duplicates...")
    progress:setPortionComplete(2, 10)
    local afterTimestampDedup = deduplicateByTimestamp(
        afterReject, SETTINGS.burstThresholdSecs)
    local burstDupCount = #afterReject - #afterTimestampDedup

    -- Step 2b: Deduplicate by perceptual hash (visual similarity)
    progress:setCaption("Removing visual duplicates...")
    progress:setPortionComplete(3, 10)
    local afterDedup, phashDupCount = deduplicateByPhash(afterTimestampDedup)

    -- ── Mode dispatch ─────────────────────────────────────────────────────
    progress:setPortionComplete(4, 10)

    local selected
    local groupOrder = {}
    local mode = SETTINGS.selectionMode or "bestof"
    local storyFallback = false
    local gapsFilled = 0

    if mode == "story" then
        progress:setCaption("Querying AI for narrative selection...")
        local storySelected, storyErr, storyGaps = selectStory(afterDedup, SETTINGS, catalog)
        if storySelected then
            selected = storySelected
            gapsFilled = storyGaps or 0
        else
            -- Fallback to Best Of with warning
            storyFallback = true
            selected, groupOrder = selectBestOf(afterDedup, SETTINGS)
        end
    else
        progress:setCaption("Selecting best photos...")
        selected, groupOrder = selectBestOf(afterDedup, SETTINGS)
    end

    -- ── Face coverage guarantee (both modes) ──────────────────────────────
    progress:setCaption("Checking face coverage...")
    progress:setPortionComplete(7, 10)

    local faceAddedCount, allPeopleNames = ensureFaceCoverage(selected, afterDedup, catalog)

    -- ── Target count overflow check ─────────────────────────────────────
    -- Allow up to 10% over target. Beyond that, trim lowest-scoring photos
    -- that were NOT added for face coverage or gap filling.
    local targetCount = SETTINGS.targetCount or 40
    local maxAllowed = math.ceil(targetCount * 1.1)
    local trimmedCount = 0

    if #selected > maxAllowed then
        -- Mark photos added for coverage so we don't trim them
        local protectedSet = {}
        -- Gap fills and face coverage additions are at the end of the list
        -- (appended after the initial selection). Protect them.
        for i = targetCount + 1, #selected do
            if selected[i] then
                protectedSet[selected[i]] = true
            end
        end

        -- Sort unprotected photos by composite score (ascending = worst first)
        local trimmable = {}
        local protected = {}
        for _, e in ipairs(selected) do
            if protectedSet[e] then
                table.insert(protected, e)
            else
                table.insert(trimmable, e)
            end
        end
        table.sort(trimmable, function(a, b)
            return a.compositeScore < b.compositeScore
        end)

        -- Trim from the weakest unprotected photos
        local keepCount = maxAllowed - #protected
        if keepCount < 0 then keepCount = 0 end
        local trimmed = {}
        for i = 1, math.min(keepCount, #trimmable) do
            table.insert(trimmed, trimmable[#trimmable - i + 1])  -- best first
        end
        trimmedCount = #selected - #trimmed - #protected

        -- Rebuild selected: kept trimmable + protected, preserving original order
        local keptSet = {}
        for _, e in ipairs(trimmed) do keptSet[e] = true end
        for _, e in ipairs(protected) do keptSet[e] = true end
        local newSelected = {}
        for _, e in ipairs(selected) do
            if keptSet[e] then table.insert(newSelected, e) end
        end
        selected = newSelected
    end

    -- ── Write sequence metadata (story mode only) ─────────────────────────
    progress:setPortionComplete(8, 10)

    if mode == "story" and not storyFallback then
        progress:setCaption("Writing story sequence...")
        local seqWriteOk, _ = LrTasks.pcall(function()
            catalog:withWriteAccessDo("AI Selects - Write Sequence", function()
                for i, e in ipairs(selected) do
                    e.photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsSequence',
                        string.format("%03d", i))
                    e.photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsStoryNote',
                        e.storyNote or "")
                end
            end, { timeout = 10 })
        end)
    end

    -- ── Create collection ─────────────────────────────────────────────────
    progress:setCaption("Creating collection...")
    progress:setPortionComplete(9, 10)

    local collectionName
    if mode == "story" and not storyFallback then
        local StoryPresets = dofile(_PLUGIN.path .. '/StoryPresets.lua')
        local preset = StoryPresets.getPreset(SETTINGS.storyPreset)
        collectionName = string.format("AI Story - %s - %s - %d of %d",
            preset.name,
            LrDate.timeToUserFormat(LrDate.currentTime(), "%Y-%m-%d %H:%M"),
            #selected, totalScored)
    else
        collectionName = string.format("AI Selects - %s - %d of %d",
            LrDate.timeToUserFormat(LrDate.currentTime(), "%Y-%m-%d %H:%M"),
            #selected, totalScored)
    end

    local selectedPhotos = {}
    for _, e in ipairs(selected) do
        table.insert(selectedPhotos, e.photo)
    end

    local newCollection
    local writeOk, writeErr = LrTasks.pcall(function()
        catalog:withWriteAccessDo("AI Selects - Create Collection", function()
            newCollection = catalog:createCollection(collectionName, nil, true)
            if newCollection then
                newCollection:addPhotos(selectedPhotos)
            end
        end, { timeout = 10 })
    end)

    -- Navigate to the new collection so the user sees the results immediately
    if newCollection then
        local navOk, _ = LrTasks.pcall(function()
            catalog:setActiveSources({ newCollection })
        end)
    end

    -- ── Build summary ─────────────────────────────────────────────────────

    -- Category breakdown
    local catBreakdown = {}
    local catCounts = {}
    local catOrder = groupOrder or {}
    for _, e in ipairs(selected) do
        local cat = e.category
        catCounts[cat] = (catCounts[cat] or 0) + 1
    end
    -- Build category order from selected if not provided
    if #catOrder == 0 then
        for _, e in ipairs(selected) do
            local cat = e.category
            local found = false
            for _, c in ipairs(catOrder) do
                if c == cat then found = true; break end
            end
            if not found then table.insert(catOrder, cat) end
        end
    end
    for _, cat in ipairs(catOrder) do
        if catCounts[cat] then
            table.insert(catBreakdown, string.format("  %s: %d", cat, catCounts[cat]))
        end
    end

    local lines = {
        string.format("Selected %d photos from %d scored (%s mode)",
            #selected, totalScored, mode == "story" and "Story" or "Best Of"),
    }
    if storyFallback then
        lines[#lines + 1] = "WARNING: Story mode failed, used Best Of fallback"
    end
    if unscored > 0 then
        lines[#lines + 1] = string.format("%d photo(s) not yet scored (skipped)", unscored)
    end
    if rejectCount > 0 then
        lines[#lines + 1] = string.format("%d rejected (low quality or flagged)", rejectCount)
    end
    if burstDupCount > 0 then
        lines[#lines + 1] = string.format("%d burst duplicates removed (timestamp)", burstDupCount)
    end
    if phashDupCount > 0 then
        lines[#lines + 1] = string.format("%d visual duplicates removed (perceptual hash)", phashDupCount)
    end
    if gapsFilled > 0 then
        lines[#lines + 1] = string.format("%d photo(s) added to fill narrative gaps", gapsFilled)
    end
    if faceAddedCount > 0 then
        lines[#lines + 1] = string.format("%d photo(s) added to ensure face coverage", faceAddedCount)
    end
    if #selected > targetCount then
        lines[#lines + 1] = string.format(
            "Note: %d photos selected (target was %d — %d extra for coverage)",
            #selected, targetCount, #selected - targetCount)
    end
    if trimmedCount > 0 then
        lines[#lines + 1] = string.format(
            "%d lower-scoring photo(s) trimmed to stay near target count", trimmedCount)
    end
    if #allPeopleNames > 0 then
        lines[#lines + 1] = string.format("People detected: %s", table.concat(allPeopleNames, ", "))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Category breakdown:"
    for _, line in ipairs(catBreakdown) do
        lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
    if writeOk then
        lines[#lines + 1] = "Collection created: " .. collectionName
    else
        lines[#lines + 1] = "Error creating collection: " .. tostring(writeErr)
    end
    if mode == "story" and not storyFallback then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Tip: Set sort order to 'Custom Order' in the toolbar to view photos in story sequence."
    end

    progress:done()
    return table.concat(lines, "\n")
end

-- ── Module export vs standalone entry point ────────────────────────────
if _G._AI_SELECTS_MODULE_LOAD then
    return { runSelection = runSelection }
end

-- Standalone entry point (menu item): wrap in async task + error handler.
LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("AISelectsSelectPhotos", function(context)
        local ok, err = LrTasks.pcall(function()
            local summary = runSelection(context)
            if summary then
                LrDialogs.message("AI Selects - Selection Complete", summary, "info")
            end
        end)
        if not ok then
            LrDialogs.message("AI Selects - Error",
                "An unexpected error occurred during selection:\n\n" .. tostring(err), "critical")
        end
    end)
end)
