--[[
  SelectPhotos.lua
  ─────────────────────────────────────────────────────────────────────────────
  Pass 2: Reads AI scores from custom metadata, applies selection pipeline,
  and creates a Collection with the final selects.

  Two selection modes:
    Best Of — quality-driven culling with temporal distribution
    Story   — snapshot-based synthesis with optional Pass 2 refinement

  Both modes share: reject → burst dedup → phash dedup → face coverage.
  They diverge at the final selection step.

  v2: 4-dimension scores (technical, composition, emotion, moment),
      composite via BatchStrategy weights, snapshot merge for story,
      synthesis prompt with event blocks, Pass 2 focused comparisons.

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

local json          = dofile(_PLUGIN.path .. '/dkjson.lua')
local Prefs         = dofile(_PLUGIN.path .. '/Prefs.lua')
local Engine        = dofile(_PLUGIN.path .. '/AIEngine.lua')
local BatchStrategy = dofile(_PLUGIN.path .. '/BatchStrategy.lua')

-- ── Logger setup (matches ScorePhotos.lua pattern) ────────────────────────
local Logger
do
    local prefs = Prefs.getPrefs()
    if prefs.enableLogging and prefs.logFolder and prefs.logFolder ~= "" then
        local logPath = LrPathUtils.child(prefs.logFolder, "selection.log")
        local f = io.open(logPath, "a")
        if f then
            Logger = {
                info = function(msg)
                    f:write(LrDate.timeToUserFormat(LrDate.currentTime(), "%H:%M:%S") ..
                        " [INFO] " .. msg .. "\n")
                    f:flush()
                end,
                warn = function(msg)
                    f:write(LrDate.timeToUserFormat(LrDate.currentTime(), "%H:%M:%S") ..
                        " [WARN] " .. msg .. "\n")
                    f:flush()
                end,
            }
        end
    end
    if not Logger then
        Logger = { info = function() end, warn = function() end }
    end
end

-- ── Read scores from custom metadata ──────────────────────────────────────
-- v2: Reads 4 dimensions. Falls back to v1 fields for migration.
local function readScores(photo)
    local technical  = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsTechnical'))
    local scoreDate  = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate')

    if not technical or not scoreDate or scoreDate == "" then
        return nil  -- not scored
    end

    local composition = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsComposition'))
    local emotion     = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsEmotion'))
    local moment      = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsMoment'))
    local composite   = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsComposite'))

    if not composition then return nil end  -- not scored with v2

    local content       = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsContent')
    local category      = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsCategory')
    local rejectStr     = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsReject')
    local phash         = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsPhash')
    local narrativeRole = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsNarrativeRole')
    local eyeQuality    = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsEyeQuality')

    return {
        photo         = photo,
        technical     = technical,
        composition   = composition,
        emotion       = emotion,
        moment        = moment,
        composite     = composite,  -- may be nil for v1 data, computed later
        content       = content or "unknown",
        category      = category or "other",
        narrativeRole = narrativeRole or "detail",
        eyeQuality    = eyeQuality or "na",
        reject        = (rejectStr == "true"),
        phash         = phash,
        scoreDate     = scoreDate,
    }
end

-- ── Deduplicate by EXIF timestamp ─────────────────────────────────────────
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
    local result = {}
    local groupBest  = entries[1]
    local groupStart = entries[1]

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
            result[#result + 1] = groupBest
            groupBest  = curr
            groupStart = curr
        end
    end
    result[#result + 1] = groupBest

    return result
end

-- ── Deduplicate by perceptual hash ────────────────────────────────────────
local PHASH_THRESHOLD = 10  -- out of 64 bits; <10 is very similar

local function deduplicateByPhash(entries)
    if #entries < 2 then return entries, 0 end

    local sorted = {}
    for _, e in ipairs(entries) do sorted[#sorted + 1] = e end
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
            kept[#kept + 1] = candidate
        else
            removed = removed + 1
        end
    end

    return kept, removed
end

-- ── Group by category ────────────────────────────────────────────────────
local function groupByCategory(entries)
    local groups = {}
    local groupOrder = {}

    for _, e in ipairs(entries) do
        local cat = e.category
        if not groups[cat] then
            groups[cat] = {}
            groupOrder[#groupOrder + 1] = cat
        end
        groups[cat][#groups[cat] + 1] = e
    end

    for _, cat in ipairs(groupOrder) do
        table.sort(groups[cat], function(a, b)
            return a.compositeScore > b.compositeScore
        end)
    end

    return groups, groupOrder
end

-- ── Distribute target count across groups ────────────────────────────────
local function distributeTarget(groups, groupOrder, targetCount, totalAvailable)
    local selected = {}
    local selectedSet = {}

    -- Proportional distribution (variety mode removed — emphasis slider handles this now)
    for _, cat in ipairs(groupOrder) do
        local proportion = #groups[cat] / totalAvailable
        local slots = math.max(1, math.floor(targetCount * proportion))
        for j = 1, math.min(slots, #groups[cat]) do
            local e = groups[cat][j]
            if not selectedSet[e.photo] then
                selected[#selected + 1] = e
                selectedSet[e.photo] = true
            end
        end
    end

    -- Fill remaining slots with highest-scoring unselected photos
    if #selected < targetCount then
        local remaining = {}
        for _, cat in ipairs(groupOrder) do
            for _, e in ipairs(groups[cat]) do
                if not selectedSet[e.photo] then
                    remaining[#remaining + 1] = e
                end
            end
        end
        table.sort(remaining, function(a, b)
            return a.compositeScore > b.compositeScore
        end)

        for _, e in ipairs(remaining) do
            if #selected >= targetCount then break end
            selected[#selected + 1] = e
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

    -- Face query can fail (e.g. no SQLite access) — non-critical, skip gracefully
    local poolPhotos = {}
    for _, e in ipairs(pool) do
        poolPhotos[#poolPhotos + 1] = e.photo
    end

    local faceMap = Engine.queryFacePeople(catalog, poolPhotos)
    if not faceMap then
        return 0, {}
    end

    -- Build set of all named people and their best photos
    local allPeople = {}
    local peopleBestPhoto = {}
    for _, e in ipairs(pool) do
        local names = faceMap[e.photo.localIdentifier]
        if names then
            for _, name in ipairs(names) do
                if not allPeople[name] then
                    allPeople[name] = true
                    allPeopleNames[#allPeopleNames + 1] = name
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
                selected[#selected + 1] = e
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

    return faceAddedCount, allPeopleNames
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MODE 1: BEST OF — quality-driven culling with temporal distribution
-- ═══════════════════════════════════════════════════════════════════════════

local function selectBestOf(pool, settings)
    local targetCount = math.min(settings.targetCount, #pool)

    -- Separate dated from undated photos
    local dated = {}
    local undated = {}
    for _, e in ipairs(pool) do
        if e.timestamp then
            dated[#dated + 1] = e
        else
            undated[#undated + 1] = e
        end
    end

    -- If few dated photos or small target, skip temporal distribution
    local numSegments = math.max(4, math.floor(targetCount / 10))
    if #dated < numSegments * 2 or targetCount <= 10 then
        local groups, groupOrder = groupByCategory(pool)
        return distributeTarget(groups, groupOrder, targetCount, #pool), groupOrder
    end

    -- Sort dated by timestamp
    table.sort(dated, function(a, b) return a.timestamp < b.timestamp end)

    -- Divide into equal time-span segments
    local minTime = dated[1].timestamp
    local maxTime = dated[#dated].timestamp
    local timeSpan = maxTime - minTime

    if timeSpan <= 0 then
        local groups, groupOrder = groupByCategory(pool)
        return distributeTarget(groups, groupOrder, targetCount, #pool), groupOrder
    end

    local segmentDuration = timeSpan / numSegments
    local segments = {}
    for s = 1, numSegments do segments[s] = {} end

    for _, e in ipairs(dated) do
        local segIdx = math.min(numSegments, math.floor((e.timestamp - minTime) / segmentDuration) + 1)
        segments[segIdx][#segments[segIdx] + 1] = e
    end

    -- Allocate target count to segments proportionally
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
            local segSelected = distributeTarget(groups, groupOrder, segTarget, #segments[s])
            for _, e in ipairs(segSelected) do
                if not selectedSet[e.photo] then
                    selected[#selected + 1] = e
                    selectedSet[e.photo] = true
                end
            end
            for _, cat in ipairs(groupOrder) do
                if not allGroupOrderSet[cat] then
                    allGroupOrder[#allGroupOrder + 1] = cat
                    allGroupOrderSet[cat] = true
                end
            end
        end
    end

    -- Handle undated photos
    if #undated > 0 and undatedTarget > 0 then
        local groups, groupOrder = groupByCategory(undated)
        local undatedSelected = distributeTarget(groups, groupOrder, undatedTarget, #undated)
        for _, e in ipairs(undatedSelected) do
            if not selectedSet[e.photo] then
                selected[#selected + 1] = e
                selectedSet[e.photo] = true
            end
        end
        for _, cat in ipairs(groupOrder) do
            if not allGroupOrderSet[cat] then
                allGroupOrder[#allGroupOrder + 1] = cat
                allGroupOrderSet[cat] = true
            end
        end
    end

    -- Trim to target count (segments may slightly overshoot)
    if #selected > targetCount then
        table.sort(selected, function(a, b)
            return a.compositeScore > b.compositeScore
        end)
        local trimmed = {}
        for i = 1, targetCount do
            trimmed[i] = selected[i]
        end
        selected = trimmed
    end

    -- Fill remaining slots with highest-scoring unselected
    if #selected < targetCount then
        selectedSet = {}
        for _, e in ipairs(selected) do selectedSet[e.photo] = true end

        local remaining = {}
        for _, e in ipairs(pool) do
            if not selectedSet[e.photo] then
                remaining[#remaining + 1] = e
            end
        end
        table.sort(remaining, function(a, b)
            return a.compositeScore > b.compositeScore
        end)
        for _, e in ipairs(remaining) do
            if #selected >= targetCount then break end
            selected[#selected + 1] = e
        end
    end

    return selected, allGroupOrder
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SNAPSHOT MERGE — combine consecutive similar snapshots into event blocks
-- ═══════════════════════════════════════════════════════════════════════════

local function mergeSnapshots(snapshots)
    if not snapshots or #snapshots == 0 then return {} end

    -- Sort by batchIndex
    local sorted = {}
    for _, s in ipairs(snapshots) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b)
        return (a.batchIndex or 0) < (b.batchIndex or 0)
    end)

    -- Merge consecutive snapshots with similar scene/action
    local events = {}
    local current = {
        batches   = { sorted[1].batchIndex or 1 },
        photoIds  = {},
        timeRange = sorted[1].timeRange or {},
        scenes    = { sorted[1].scene or "" },
        people    = {},
        moods     = { sorted[1].mood or "" },
        settings  = { sorted[1].setting or "" },
        actions   = { sorted[1].action or "" },
    }

    -- Collect photo IDs and people from first snapshot
    if sorted[1].photoIds then
        for _, id in ipairs(sorted[1].photoIds) do
            current.photoIds[#current.photoIds + 1] = id
        end
    end
    if sorted[1].people then
        for _, p in ipairs(sorted[1].people) do
            current.people[p] = true
        end
    end

    local function shouldMerge(a, b)
        -- Simple heuristic: merge if scene or action keywords overlap
        local sceneA = (a.scene or ""):lower()
        local sceneB = (b.scene or ""):lower()
        local actionA = (a.action or ""):lower()
        local actionB = (b.action or ""):lower()

        -- Check for shared significant words (>3 chars)
        for word in sceneA:gmatch("%w+") do
            if #word > 3 and sceneB:find(word, 1, true) then return true end
        end
        for word in actionA:gmatch("%w+") do
            if #word > 3 and actionB:find(word, 1, true) then return true end
        end

        return false
    end

    local function flushEvent()
        -- Convert people set to array
        local peopleArr = {}
        for p, _ in pairs(current.people) do
            peopleArr[#peopleArr + 1] = p
        end

        events[#events + 1] = {
            batches   = current.batches,
            photoIds  = current.photoIds,
            timeRange = {
                start = current.timeRange.start,
                ["end"] = current.timeRange["end"],
            },
            scene     = table.concat(current.scenes, "; "),
            people    = peopleArr,
            mood      = table.concat(current.moods, ", "),
            setting   = table.concat(current.settings, "; "),
            action    = table.concat(current.actions, "; "),
        }
    end

    for i = 2, #sorted do
        local snap = sorted[i]
        if shouldMerge(sorted[i - 1], snap) then
            -- Merge into current event
            current.batches[#current.batches + 1] = snap.batchIndex or i
            if snap.scene and snap.scene ~= "" then
                current.scenes[#current.scenes + 1] = snap.scene
            end
            if snap.mood and snap.mood ~= "" then
                current.moods[#current.moods + 1] = snap.mood
            end
            if snap.setting and snap.setting ~= "" then
                current.settings[#current.settings + 1] = snap.setting
            end
            if snap.action and snap.action ~= "" then
                current.actions[#current.actions + 1] = snap.action
            end
            if snap.photoIds then
                for _, id in ipairs(snap.photoIds) do
                    current.photoIds[#current.photoIds + 1] = id
                end
            end
            if snap.people then
                for _, p in ipairs(snap.people) do
                    current.people[p] = true
                end
            end
            -- Extend time range
            if snap.timeRange then
                if snap.timeRange["end"] then
                    current.timeRange["end"] = snap.timeRange["end"]
                end
            end
        else
            -- Flush current event and start a new one
            flushEvent()
            current = {
                batches   = { snap.batchIndex or i },
                photoIds  = {},
                timeRange = snap.timeRange or {},
                scenes    = { snap.scene or "" },
                people    = {},
                moods     = { snap.mood or "" },
                settings  = { snap.setting or "" },
                actions   = { snap.action or "" },
            }
            if snap.photoIds then
                for _, id in ipairs(snap.photoIds) do
                    current.photoIds[#current.photoIds + 1] = id
                end
            end
            if snap.people then
                for _, p in ipairs(snap.people) do
                    current.people[p] = true
                end
            end
        end
    end
    flushEvent()

    Logger.info(string.format("Merged %d snapshots into %d events", #sorted, #events))
    return events
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MODE 2: STORY — snapshot-based synthesis with Pass 2 refinement
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
            composition    = e.composition,
            emotion        = e.emotion,
            moment         = e.moment,
            composite      = math.floor(e.compositeScore * 100 + 0.5) / 100,
            content        = e.content,
            category       = e.category,
            narrative_role = e.narrativeRole,
            eye_quality    = e.eyeQuality,
            timestamp      = ts,
            people         = faceMap[e.photo.localIdentifier] or {},
        }
        items[#items + 1] = item
    end
    return items
end

local function selectStory(pool, settings, catalog, snapshots, progress)
    local targetCount = math.min(settings.targetCount, #pool)

    -- Load story presets
    local StoryPresets = dofile(_PLUGIN.path .. '/StoryPresets.lua')
    local preset = StoryPresets.getPreset(settings.storyPreset)

    -- Build face map for all pool photos
    local poolPhotos = {}
    for _, e in ipairs(pool) do poolPhotos[#poolPhotos + 1] = e.photo end
    local faceMap = Engine.queryFacePeople(catalog, poolPhotos) or {}

    -- Build metadata summary
    local metadataItems = buildMetadataSummary(pool, faceMap)
    local summaryJson = json.encode(metadataItems)

    -- Merge snapshots into event blocks
    local events = mergeSnapshots(snapshots)
    local eventBlocksJson
    if #events > 0 then
        eventBlocksJson = json.encode(events)
    else
        eventBlocksJson = "[No visual snapshots available — use photo metadata to infer events.]"
    end

    -- Context window check
    local estimatedTokens = (#summaryJson + #eventBlocksJson) / 4
    local tokenLimits = {
        claude = 150000,
        openai = 100000,
        gemini = 800000,
    }
    local tokenLimit = tokenLimits[settings.provider] or 6000

    if estimatedTokens > tokenLimit then
        -- Pre-filter: sort by composite score, shrink candidate pool
        local candidateCount = math.min(#pool, targetCount * 3)
        local sortedPool = {}
        for _, e in ipairs(pool) do sortedPool[#sortedPool + 1] = e end
        table.sort(sortedPool, function(a, b)
            return a.compositeScore > b.compositeScore
        end)

        while candidateCount > targetCount do
            local filteredPool = {}
            for i = 1, candidateCount do
                filteredPool[#filteredPool + 1] = sortedPool[i]
            end
            metadataItems = buildMetadataSummary(filteredPool, faceMap)
            summaryJson = json.encode(metadataItems)
            estimatedTokens = (#summaryJson + #eventBlocksJson) / 4
            if estimatedTokens <= tokenLimit then break end
            candidateCount = math.floor(candidateCount * 0.7)
        end

        if estimatedTokens > tokenLimit and candidateCount <= targetCount then
            return nil, string.format(
                "Too many photos for this model's context window (%d photos, ~%dK tokens). " ..
                "Reduce the number of source photos or switch to a cloud provider.",
                #pool, math.floor(estimatedTokens / 1000))
        end
    end

    -- Build the prompt from SYNTHESIS_PROMPT_TEMPLATE
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

    local prompt = Engine.SYNTHESIS_PROMPT_TEMPLATE
    local replacements = {
        ["%%PRESET_NAME%%"]              = preset.name or "Custom",
        ["%%GUIDELINES%%"]               = guidelines,
        ["%%CUSTOM_INSTRUCTIONS%%"]      = "",
        ["%%EVENT_BLOCKS%%"]             = eventBlocksJson,
        ["%%TARGET_COUNT%%"]             = tostring(targetCount),
        ["%%CHRONOLOGICAL_CONSTRAINT%%"] = chronoConstraint,
        ["%%PEOPLE_CONSTRAINT%%"]        = peopleConstraint,
        ["%%METADATA_JSON%%"]            = summaryJson,
    }
    for placeholder, value in pairs(replacements) do
        prompt = prompt:gsub(placeholder, function() return value end)
    end

    -- AI call (text-only, no images)
    if progress then progress:setCaption("Querying AI for narrative selection...") end
    local maxTokens = BatchStrategy.getMaxTokens(settings.provider, "synthesis")
    local response, queryErr = Engine.queryText(prompt, settings, maxTokens)

    if not response then
        return nil, "Story AI call failed: " .. tostring(queryErr)
    end

    -- Parse response
    local validIds = {}
    local entryById = {}
    for _, e in ipairs(pool) do
        validIds[#validIds + 1] = e.photo.localIdentifier
        entryById[tostring(e.photo.localIdentifier)] = e
    end

    local storySelection, parseErr = Engine.parseStoryResponse(response, validIds)

    if not storySelection then
        -- Retry once with simplified prompt
        Logger.warn("Story parse failed, retrying with simplified prompt: " .. tostring(parseErr))
        local retryPrompt = string.format(
            "Select exactly %d photos from this list and return them in narrative order.\n" ..
            "Return ONLY a JSON array of objects with: id (number), position (1 to %d), " ..
            "beat (string), role (string), note (5-10 words), alternates (array of 1-2 IDs).\n\n%s",
            targetCount, targetCount, summaryJson
        )
        local retryResp, retryErr = Engine.queryText(retryPrompt, settings, maxTokens)
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
            e.storyNote     = item.note or ""
            e.storyBeat     = item.beat or ""
            e.storyRole     = item.role or "detail"
            e.storyPosition = item.position or #selected + 1
            e.alternates    = item.alternates or {}
            selected[#selected + 1] = e
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
                    selected[#selected + 1] = best
                    selectedSet[best.photo] = true
                    gapsFilled = gapsFilled + 1
                end
            end
        end
    end

    -- Gap detection: timeline quartiles
    local datedPool = {}
    for _, e in ipairs(pool) do
        if e.timestamp then datedPool[#datedPool + 1] = e end
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
                        selected[#selected + 1] = best
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
-- PASS 2 REFINEMENT — focused per-beat comparisons for story mode
-- ═══════════════════════════════════════════════════════════════════════════

local function runPass2Refinement(selected, pool, settings, catalog, progress)
    if not settings.enablePass2 then return 0 end
    if settings.provider == "ollama" then return 0 end  -- not supported for local models

    -- Build entry lookup for alternates
    local entryById = {}
    for _, e in ipairs(pool) do
        entryById[tostring(e.photo.localIdentifier)] = e
    end

    local swapCount = 0
    local total = 0

    -- Count eligible beats first for progress
    for _, e in ipairs(selected) do
        if e.alternates and #e.alternates > 0 then
            -- Check if any alternate is within 1 composite point
            for _, altId in ipairs(e.alternates) do
                local alt = entryById[altId]
                if alt and math.abs(alt.compositeScore - e.compositeScore) <= 1.0 then
                    total = total + 1
                    break
                end
            end
        end
    end

    if total == 0 then
        Logger.info("Pass 2: no close-scoring alternates found, skipping")
        return 0
    end

    Logger.info(string.format("Pass 2: %d beats with close alternates to compare", total))
    local completed = 0

    for i, e in ipairs(selected) do repeat
        if not e.alternates or #e.alternates == 0 then break end

        -- Collect close-scoring alternates
        local closeAlts = {}
        for _, altId in ipairs(e.alternates) do
            local alt = entryById[altId]
            if alt and math.abs(alt.compositeScore - e.compositeScore) <= 1.0 then
                closeAlts[#closeAlts + 1] = alt
            end
        end
        if #closeAlts == 0 then break end

        -- Render primary + alternates
        completed = completed + 1
        if progress then
            progress:setCaption(string.format("Pass 2 refinement (%d/%d)...", completed, total))
        end

        local images = {}
        local imageIds = {}

        -- Render primary
        local ts = tostring(LrDate.currentTime()) .. "_p2_" .. i
        local primaryImg = Engine.prepareImage(e.photo, ts .. "_pri", settings.provider, settings.renderSize)
        if not primaryImg then break end

        images[1] = primaryImg
        imageIds[1] = tostring(e.photo.localIdentifier)

        -- Render alternates (max 2)
        local allRendered = true
        for j, alt in ipairs(closeAlts) do
            if j > 2 then break end
            local altImg = Engine.prepareImage(alt.photo, ts .. "_alt" .. j, settings.provider, settings.renderSize)
            if altImg then
                images[#images + 1] = altImg
                imageIds[#imageIds + 1] = tostring(alt.photo.localIdentifier)
            else
                allRendered = false
            end
        end

        if #images < 2 then break end

        -- Query Pass 2
        local selectedId, p2Err = Engine.queryPass2(
            images, imageIds,
            e.storyBeat or "", e.storyRole or "", e.storyNote or "",
            settings
        )

        -- Note: prepareImage() handles temp file cleanup internally,
        -- so no cleanup needed here.

        if selectedId and selectedId ~= imageIds[1] then
            -- Swap: the alternate was judged better
            local newEntry = entryById[selectedId]
            if newEntry then
                newEntry.storyNote     = e.storyNote .. " (Pass 2 swap)"
                newEntry.storyBeat     = e.storyBeat
                newEntry.storyRole     = e.storyRole
                newEntry.storyPosition = e.storyPosition
                selected[i] = newEntry
                swapCount = swapCount + 1
                Logger.info(string.format("Pass 2: swapped beat %d — %s → %s",
                    i, imageIds[1], selectedId))
            end
        end

    until true end

    Logger.info(string.format("Pass 2: %d swaps out of %d comparisons", swapCount, total))
    return swapCount
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MAIN SELECTION PIPELINE
-- ═══════════════════════════════════════════════════════════════════════════

-- Core selection logic. Exported for ScoreAndSelect.lua.
-- overrides: optional table to override specific settings (from run dialog)
-- snapshots: optional array of batch snapshots from scoring (for story mode)
-- Returns summary string, or nil if no work done.
local function runSelection(context, overrides, snapshots)
    local SETTINGS = Prefs.getPrefs()

    -- Apply overrides from run dialog
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

    -- Progress scope
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
            scored[#scored + 1] = entry
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

    -- Compute composite scores using BatchStrategy weights
    local weights = BatchStrategy.computeWeights(SETTINGS.emphasisSlider)
    for _, e in ipairs(scored) do
        if e.composite then
            -- Use stored composite if available (already computed during scoring)
            e.compositeScore = e.composite
        else
            -- Compute from dimensions (v1 migration path)
            local scores = {
                technical   = e.technical,
                composition = e.composition,
                emotion     = e.emotion,
                moment      = e.moment,
            }
            e.compositeScore = BatchStrategy.computeComposite(scores, weights, e.eyeQuality)
        end
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
            afterReject[#afterReject + 1] = e
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
    local storyFallback = false
    local gapsFilled = 0
    local pass2Swaps = 0

    if mode == "story" then
        progress:setCaption("Querying AI for narrative selection...")
        local storySelected, storyErr, storyGaps = selectStory(
            afterDedup, SETTINGS, catalog, snapshots, progress)
        if storySelected then
            selected = storySelected
            gapsFilled = storyGaps or 0

            -- Pass 2 refinement (optional)
            if SETTINGS.enablePass2 and SETTINGS.provider ~= "ollama" then
                progress:setPortionComplete(6, 10)
                pass2Swaps = runPass2Refinement(selected, afterDedup, SETTINGS, catalog, progress)
            end
        else
            -- Fallback to Best Of with warning
            Logger.warn("Story mode failed: " .. tostring(storyErr) .. " — falling back to Best Of")
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

    -- ── Target count overflow check ───────────────────────────────────────
    local targetCount = SETTINGS.targetCount or 40
    local maxAllowed = math.ceil(targetCount * 1.1)
    local trimmedCount = 0

    if #selected > maxAllowed then
        local protectedSet = {}
        for i = targetCount + 1, #selected do
            if selected[i] then
                protectedSet[selected[i]] = true
            end
        end

        local trimmable = {}
        local protected = {}
        for _, e in ipairs(selected) do
            if protectedSet[e] then
                protected[#protected + 1] = e
            else
                trimmable[#trimmable + 1] = e
            end
        end
        table.sort(trimmable, function(a, b)
            return a.compositeScore < b.compositeScore
        end)

        local keepCount = maxAllowed - #protected
        if keepCount < 0 then keepCount = 0 end
        local trimmed = {}
        for i = 1, math.min(keepCount, #trimmable) do
            trimmed[#trimmed + 1] = trimmable[#trimmable - i + 1]
        end
        trimmedCount = #selected - #trimmed - #protected

        local keptSet = {}
        for _, e in ipairs(trimmed) do keptSet[e] = true end
        for _, e in ipairs(protected) do keptSet[e] = true end
        local newSelected = {}
        for _, e in ipairs(selected) do
            if keptSet[e] then newSelected[#newSelected + 1] = e end
        end
        selected = newSelected
    end

    -- ── Write sequence metadata (story mode only) ─────────────────────────
    progress:setPortionComplete(8, 10)

    if mode == "story" and not storyFallback then
        progress:setCaption("Writing story sequence...")
        catalog:withWriteAccessDo("AI Selects - Write Sequence", function()
            for i, e in ipairs(selected) do
                e.photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsSequence',
                    string.format("%03d", i))
                e.photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsStoryNote',
                    e.storyNote or "")
                e.photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsNarrativeRole',
                    e.storyRole or e.narrativeRole or "")
            end
        end, { timeout = 10 })
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
        selectedPhotos[#selectedPhotos + 1] = e.photo
    end

    local newCollection
    catalog:withWriteAccessDo("AI Selects - Create Collection", function()
        newCollection = catalog:createCollection(collectionName, nil, true)
        if newCollection then
            newCollection:addPhotos(selectedPhotos)
        end
    end, { timeout = 10 })

    -- Navigate to the new collection
    if newCollection then
        catalog:setActiveSources({ newCollection })
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
    if #catOrder == 0 then
        for _, e in ipairs(selected) do
            local cat = e.category
            local found = false
            for _, c in ipairs(catOrder) do
                if c == cat then found = true; break end
            end
            if not found then catOrder[#catOrder + 1] = cat end
        end
    end
    for _, cat in ipairs(catOrder) do
        if catCounts[cat] then
            catBreakdown[#catBreakdown + 1] = string.format("  %s: %d", cat, catCounts[cat])
        end
    end

    -- Score distribution
    local function scoreDistribution(entries, field)
        local buckets = {}
        for b = 1, 10 do buckets[b] = 0 end
        for _, e in ipairs(entries) do
            local val = e[field]
            if val then
                local bucket = math.max(1, math.min(10, math.floor(val + 0.5)))
                buckets[bucket] = buckets[bucket] + 1
            end
        end
        local parts = {}
        for b = 1, 10 do
            if buckets[b] > 0 then
                parts[#parts + 1] = string.format("%d:%d", b, buckets[b])
            end
        end
        return table.concat(parts, " ")
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
    if pass2Swaps > 0 then
        lines[#lines + 1] = string.format("%d photo(s) swapped by Pass 2 refinement", pass2Swaps)
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

    -- Score distributions in selected set
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Selected score distributions:"
    lines[#lines + 1] = "  Technical:   " .. scoreDistribution(selected, "technical")
    lines[#lines + 1] = "  Composition: " .. scoreDistribution(selected, "composition")
    lines[#lines + 1] = "  Emotion:     " .. scoreDistribution(selected, "emotion")
    lines[#lines + 1] = "  Moment:      " .. scoreDistribution(selected, "moment")

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

-- ── Module export vs standalone entry point ──────────────────────────────
if _G._AI_SELECTS_MODULE_LOAD then
    return { runSelection = runSelection }
end

-- Standalone entry point (menu item): wrap in async task.
LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("AISelectsSelectPhotos", function(context)
        local summary = runSelection(context)
        if summary then
            LrDialogs.message("AI Selects - Selection Complete", summary, "info")
        end
    end)
end)
