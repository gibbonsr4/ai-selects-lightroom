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

-- ── Deduplicate by content description (near-duplicate detection) ────────
-- Catches visually similar photos that burst dedup misses (e.g., trophy
-- poses taken seconds apart at different timestamps). Compares word overlap
-- in the AI-generated content descriptions + timestamp proximity.
local CONTENT_DEDUP_WORD_OVERLAP = 0.60   -- fraction of shared words
local CONTENT_DEDUP_TIME_WINDOW  = 60     -- seconds

local function tokenize(text)
    local words = {}
    for word in (text or ""):lower():gmatch("%w+") do
        if #word > 2 then  -- skip tiny words (a, of, in, etc.)
            words[#words + 1] = word
        end
    end
    return words
end

local function wordOverlap(wordsA, wordsB)
    if #wordsA == 0 or #wordsB == 0 then return 0 end

    local setB = {}
    for _, w in ipairs(wordsB) do setB[w] = true end

    local shared = 0
    for _, w in ipairs(wordsA) do
        if setB[w] then shared = shared + 1 end
    end

    -- Overlap relative to the smaller set
    local smaller = math.min(#wordsA, #wordsB)
    return shared / smaller
end

local function deduplicateByContent(entries)
    if #entries < 2 then return entries, 0 end

    -- Sort by composite score descending — keep higher-scored photo
    local sorted = {}
    for _, e in ipairs(entries) do sorted[#sorted + 1] = e end
    table.sort(sorted, function(a, b)
        return a.compositeScore > b.compositeScore
    end)

    -- Pre-tokenize all content descriptions
    for _, e in ipairs(sorted) do
        e._contentTokens = tokenize(e.content)
    end

    local kept = {}
    local removed = 0

    for _, candidate in ipairs(sorted) do
        local dominated = false
        for _, keeper in ipairs(kept) do
            -- Only compare photos within the time window
            if candidate.timestamp and keeper.timestamp then
                local timeDiff = math.abs(candidate.timestamp - keeper.timestamp)
                if timeDiff <= CONTENT_DEDUP_TIME_WINDOW then
                    local overlap = wordOverlap(candidate._contentTokens, keeper._contentTokens)
                    if overlap >= CONTENT_DEDUP_WORD_OVERLAP then
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

    -- Clean up temporary tokens
    for _, e in ipairs(kept) do e._contentTokens = nil end

    return kept, removed
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
-- v3 STORY MODE: Multi-pass pipeline (Passes 2-3)
-- Pass 2: Story Assembly (text-only → beat list)
-- Pass 3A: Code pre-filter (hard constraints per beat)
-- Pass 3B: AI text ranking (semantic matching per beat)
-- Passes 4-6 (vision) will be added in later phases.
-- ═══════════════════════════════════════════════════════════════════════════

local function selectStoryV3(pool, settings, catalog, snapshots, photoStore, progress)
    local targetCount = math.min(settings.targetCount, #pool)
    local storyPrompt = settings.storyPrompt or ""
    local storyEmphasis = settings.storyEmphasis or ""

    if storyPrompt == "" then
        return nil, "No story prompt provided"
    end

    -- ── Pass 2: Story Assembly (text-only) ───────────────────────────────
    progress:setCaption("Pass 2: Planning story beats...")

    -- Build event timeline from snapshots
    local events = mergeSnapshots(snapshots)
    local eventTimeline
    if #events > 0 then
        local eventParts = {}
        for i, ev in ipairs(events) do
            local batchRange = ""
            if ev.batches and #ev.batches > 0 then
                batchRange = string.format("Batches %s", table.concat(ev.batches, ","))
            end
            local timeStr = ""
            if ev.timeRange and ev.timeRange.start then
                timeStr = ev.timeRange.start
                if ev.timeRange["end"] then
                    timeStr = timeStr .. " to " .. ev.timeRange["end"]
                end
            end
            local line = string.format("Event %d (%s, %s): %s",
                i, batchRange, timeStr,
                (ev.scene or "") .. ". " .. (ev.action or ""))
            if ev.people and #ev.people > 0 then
                line = line .. " People: " .. table.concat(ev.people, ", ") .. "."
            end
            if ev.mood and ev.mood ~= "" then
                line = line .. " Mood: " .. ev.mood .. "."
            end
            eventParts[#eventParts + 1] = line
        end
        eventTimeline = table.concat(eventParts, "\n\n")
    else
        eventTimeline = "[No visual snapshots available — use photo metadata to infer events.]"
    end

    -- Build metadata rollup from photoStore
    local rollup = Engine.buildMetadataRollup(photoStore)
    rollup.targetCount = targetCount

    -- Build all-photos text list (sorted chronologically)
    local photoList = {}
    for id, store in pairs(photoStore) do
        if not store.reject then
            photoList[#photoList + 1] = {
                id = id,
                store = store,
                time = store.captureTime or 0,
            }
        end
    end
    table.sort(photoList, function(a, b) return a.time < b.time end)

    local allPhotosLines = {}
    for i, p in ipairs(photoList) do
        local s = p.store
        local timeStr = "unknown"
        if s.captureTime then
            timeStr = LrDate.timeToUserFormat(s.captureTime, "%H:%M:%S")
        end
        local peopleTxt = ""
        if s.people and #s.people > 0 then
            peopleTxt = ", people=[" .. table.concat(s.people, ", ") .. "]"
        end
        allPhotosLines[#allPhotosLines + 1] = string.format(
            'Photo %d: composite=%.1f, T=%d C=%d E=%d M=%d, category=%s, eye=%s%s, time=%s\n  "%s"',
            i, s.composite,
            s.scores.technical, s.scores.composition, s.scores.emotion, s.scores.moment,
            s.category, s.eyeQuality, peopleTxt, timeStr,
            s.content
        )
    end
    local allPhotosText = table.concat(allPhotosLines, "\n")

    -- Build and send the story assembly prompt
    local assemblyPrompt = Engine.buildStoryAssemblyPrompt(
        storyPrompt, storyEmphasis, eventTimeline, rollup, allPhotosText, targetCount
    )

    Logger.info(string.format("Pass 2: Story assembly prompt length: %d chars, %d photos",
        #assemblyPrompt, #photoList))

    local maxTokens = BatchStrategy.getMaxTokens(settings.provider, "synthesis")
    local assemblyResponse, assemblyErr = Engine.queryText(assemblyPrompt, settings, maxTokens)

    if not assemblyResponse then
        return nil, "Story assembly failed: " .. tostring(assemblyErr)
    end

    -- Parse beat list
    local beatResult, beatErr = Engine.parseBeatListResponse(assemblyResponse)
    if not beatResult then
        return nil, "Could not parse story assembly: " .. tostring(beatErr)
    end

    local beats = beatResult.beats
    Logger.info(string.format("Pass 2: Planned %d beats — \"%s\"",
        #beats, beatResult.storyTitle or ""))
    for _, beat in ipairs(beats) do
        Logger.info(string.format("  Beat %d: %s [%s] (min_composite=%.1f)",
            beat.position, beat.beat, beat.narrativeRole,
            beat.searchCriteria.minComposite))
    end
    Logger.info("Pass 2 cost: " .. Engine.formatCostSummary())

    -- ── Pass 3A: Code pre-filter ─────────────────────────────────────────
    progress:setCaption("Pass 3: Filtering candidates per beat...")
    progress:setPortionComplete(5, 10)

    -- Build lookup from pool entries (keyed by localIdentifier)
    local poolById = {}
    for _, e in ipairs(pool) do
        poolById[tostring(e.photo.localIdentifier)] = e
    end

    local usedIds = {}  -- track photos already selected for prior beats
    local candidatesByBeat = {}

    for beatIdx, beat in ipairs(beats) do
        local sc = beat.searchCriteria
        local candidates = {}

        for _, e in ipairs(pool) do
            local id = tostring(e.photo.localIdentifier)
            local dominated = false

            -- Hard filters
            repeat
                -- Already used by a prior beat
                if usedIds[id] then dominated = true; break end

                -- Reject filter
                if e.reject then dominated = true; break end

                -- Composite threshold
                if e.compositeScore < sc.minComposite then dominated = true; break end

                -- Eye quality filter (for portrait/people beats)
                local isPersonBeat = false
                if sc.categoryHint then
                    for _, cat in ipairs(sc.categoryHint) do
                        if cat == "portrait" or cat == "event" then isPersonBeat = true; break end
                    end
                end
                if isPersonBeat and e.eyeQuality == "closed" then dominated = true; break end

                -- People filter: if must_have mentions people, check face data
                if sc.mustHave and #sc.mustHave > 0 then
                    local store = photoStore[id]
                    if store then
                        for _, req in ipairs(sc.mustHave) do
                            local reqLower = req:lower()
                            -- Check for "all N people" or "group shot" requirements
                            if reqLower:find("all") and reqLower:find("people") then
                                -- Require 3+ people
                                if not store.people or #store.people < 3 then
                                    dominated = true; break
                                end
                            end
                            -- Check for specific person name
                            if store.people then
                                for _, name in ipairs(store.people) do
                                    if reqLower:find(name:lower()) then
                                        -- Found the person, this requirement is satisfied
                                    end
                                end
                            end
                        end
                    end
                end
            until true

            if not dominated then
                candidates[#candidates + 1] = {
                    id        = id,
                    entry     = e,
                    content   = e.content,
                    composite = e.compositeScore,
                    category  = e.category,
                    time      = e.timestamp and LrDate.timeToUserFormat(e.timestamp, "%H:%M:%S") or "unknown",
                    people    = photoStore[id] and photoStore[id].people or {},
                }
            end
        end

        -- Sort by composite descending
        table.sort(candidates, function(a, b) return a.composite > b.composite end)

        -- If too few candidates, relax filters progressively
        if #candidates < 8 then
            Logger.info(string.format("  Beat %d: only %d candidates after filtering, relaxing...",
                beatIdx, #candidates))
            -- Re-run with lower composite threshold
            local relaxed = {}
            for _, e in ipairs(pool) do
                local id = tostring(e.photo.localIdentifier)
                if not usedIds[id] and not e.reject then
                    relaxed[#relaxed + 1] = {
                        id        = id,
                        entry     = e,
                        content   = e.content,
                        composite = e.compositeScore,
                        category  = e.category,
                        time      = e.timestamp and LrDate.timeToUserFormat(e.timestamp, "%H:%M:%S") or "unknown",
                        people    = photoStore[id] and photoStore[id].people or {},
                    }
                end
            end
            table.sort(relaxed, function(a, b) return a.composite > b.composite end)
            -- Take top 30 (or all if fewer)
            candidates = {}
            for i = 1, math.min(30, #relaxed) do
                candidates[#candidates + 1] = relaxed[i]
            end
        end

        -- Cap candidates at 40 for the AI ranking call
        if #candidates > 40 then
            local capped = {}
            for i = 1, 40 do capped[#capped + 1] = candidates[i] end
            candidates = capped
        end

        candidatesByBeat[beatIdx] = candidates
        Logger.info(string.format("  Beat %d: %d candidates for \"%s\"",
            beatIdx, #candidates, beat.beat))
    end

    -- ── Pass 3B: AI text ranking (per beat) ──────────────────────────────
    -- Ranks candidates semantically. Does NOT make final selections — Pass 4 does.
    progress:setCaption("Pass 3B: AI ranking candidates per beat...")
    progress:setPortionComplete(5, 10)

    for beatIdx, beat in ipairs(beats) do
        local candidates = candidatesByBeat[beatIdx]
        if not candidates or #candidates == 0 then
            Logger.warn(string.format("  Beat %d: no candidates, skipping", beatIdx))
        elseif #candidates <= 3 or settings.provider == "ollama" then
            -- Too few to rank, or Ollama (skip 3B) — already sorted by composite
            Logger.info(string.format("  Beat %d: %d candidates, using composite order",
                beatIdx, #candidates))
        else
            -- Build numbered candidate list for the AI
            local numberedCandidates = {}
            for i, c in ipairs(candidates) do
                numberedCandidates[#numberedCandidates + 1] = {
                    num       = i,
                    content   = c.content,
                    composite = c.composite,
                    category  = c.category,
                    people    = c.people,
                    time      = c.time,
                }
            end

            -- Build and send ranking prompt
            local rankPrompt = Engine.buildCandidateRankingPrompt(
                beatIdx, #beats, beat.description or beat.beat,
                beat.narrativeRole, beat.searchCriteria, numberedCandidates
            )

            local rankResponse, rankErr = Engine.queryText(rankPrompt, settings, 256)

            local ranked = nil
            if rankResponse then
                ranked, rankErr = Engine.parseCandidateRankingResponse(rankResponse)
            end

            -- Re-order candidates by AI ranking (keeping only top 8 for vision)
            if ranked and #ranked > 0 then
                local reordered = {}
                local seen = {}
                for _, pos in ipairs(ranked) do
                    if pos >= 1 and pos <= #candidates and not seen[pos] then
                        seen[pos] = true
                        reordered[#reordered + 1] = candidates[pos]
                    end
                    if #reordered >= 8 then break end
                end
                -- Append any remaining candidates not in ranked list
                for i, c in ipairs(candidates) do
                    if not seen[i] and #reordered < 8 then
                        reordered[#reordered + 1] = c
                    end
                end
                candidatesByBeat[beatIdx] = reordered
                Logger.info(string.format("  Beat %d: AI-ranked %d → top %d candidates",
                    beatIdx, #candidates, #reordered))
            else
                -- AI ranking failed — keep composite order, trim to top 8
                if #candidates > 8 then
                    local trimmed = {}
                    for i = 1, 8 do trimmed[i] = candidates[i] end
                    candidatesByBeat[beatIdx] = trimmed
                end
                Logger.info(string.format("  Beat %d: ranking failed, using composite top %d",
                    beatIdx, math.min(#candidates, 8)))
            end
        end
    end
    Logger.info("Pass 3 cost: " .. Engine.formatCostSummary())

    -- ── Pre-render image cache for vision passes (4-6) ─────────────────────
    -- Render JPEG thumbnails for all unique candidates so Passes 4-6 don't
    -- re-render the same photo multiple times.
    if settings.provider ~= "ollama" then
        -- Collect all unique candidate photo IDs across all beats
        local candidateIds = {}
        local candidatePhotos = {}  -- id → photo object
        for _, candidates in pairs(candidatesByBeat) do
            for _, c in ipairs(candidates) do
                if not candidateIds[c.id] then
                    candidateIds[c.id] = true
                    candidatePhotos[c.id] = c.entry.photo
                end
            end
        end

        -- Count how many need rendering (skip already-cached)
        local toRender = {}
        for id, photo in pairs(candidatePhotos) do
            local store = photoStore[id]
            if not store or not store.cachedImagePath then
                toRender[#toRender + 1] = { id = id, photo = photo }
            end
        end

        if #toRender > 0 then
            Logger.info(string.format("Image cache: rendering %d candidate photos at %dpx",
                #toRender, settings.renderSize))
            progress:setCaption(string.format("Caching %d candidate images...", #toRender))

            local ts = tostring(math.floor(LrDate.currentTime() * 1000))
            local cached = 0
            for i, item in ipairs(toRender) do
                local imgPath, imgSize = Engine.renderImage(item.photo, ts .. "_cache_" .. i, settings.renderSize)
                if imgPath then
                    if not photoStore[item.id] then
                        photoStore[item.id] = {}
                    end
                    photoStore[item.id].cachedImagePath = imgPath
                    cached = cached + 1
                else
                    Logger.warn(string.format("Image cache: failed to render %s", item.id))
                end
                LrTasks.yield()
            end
            Logger.info(string.format("Image cache: %d/%d rendered successfully", cached, #toRender))
        end
    end

    -- ── Pass 4: Beat Casting (vision) ─────────────────────────────────────
    -- For cloud providers: send candidate images per beat, AI picks best match.
    -- For Ollama: use text-ranked order (skip vision casting).
    progress:setCaption("Pass 4: Vision beat casting...")
    progress:setPortionComplete(6, 10)

    -- Reset usedIds for final selection pass
    usedIds = {}
    local finalSelection = {}
    local beatResults = {}   -- {primary=id, backup=id, flag=...} per beat

    if settings.provider == "ollama" then
        -- Ollama: skip vision casting, use text-ranked/composite order
        Logger.info("Pass 4: Ollama — using text-ranked selections (no vision)")
        for beatIdx, beat in ipairs(beats) do
            local candidates = candidatesByBeat[beatIdx]
            if candidates and #candidates > 0 then
                for _, c in ipairs(candidates) do
                    if not usedIds[c.id] then
                        usedIds[c.id] = true
                        local e = c.entry
                        e.storyBeat     = beat.beat
                        e.storyRole     = beat.narrativeRole
                        e.storyNote     = beat.description
                        e.storyPosition = beat.position
                        finalSelection[#finalSelection + 1] = e
                        beatResults[beatIdx] = { primaryId = c.id }
                        Logger.info(string.format("  Beat %d: selected — %s",
                            beatIdx, (c.content or ""):sub(1, 60)))
                        break
                    end
                end
            end
        end
    else
        -- Cloud providers: vision-based beat casting in sequential waves
        -- Waves of 3 beats: each wave sees previous selections as context
        local WAVE_SIZE = 3
        local previousSelections = {}  -- {position, content} for redundancy context

        local totalWaves = math.ceil(#beats / WAVE_SIZE)
        for waveIdx = 1, totalWaves do
            local waveStart = (waveIdx - 1) * WAVE_SIZE + 1
            local waveEnd   = math.min(waveIdx * WAVE_SIZE, #beats)

            Logger.info(string.format("Pass 4: Wave %d/%d — beats %d-%d",
                waveIdx, totalWaves, waveStart, waveEnd))
            progress:setCaption(string.format("Pass 4: Beat casting (wave %d/%d)...",
                waveIdx, totalWaves))

            for beatIdx = waveStart, waveEnd do
                local beat = beats[beatIdx]
                local candidates = candidatesByBeat[beatIdx]

                if not candidates or #candidates == 0 then
                    Logger.warn(string.format("  Beat %d: no candidates, skipping", beatIdx))
                else
                    -- Render candidate images
                    local images = {}     -- {base64, fileSize}
                    local labels = {}     -- "[Photo N]"
                    local validCandidates = {}  -- candidates with successful renders

                    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
                    for i, c in ipairs(candidates) do
                        if usedIds[c.id] then
                            -- Skip already-used photos
                        else
                            -- Check photoStore for cached image or render fresh
                            local store = photoStore[c.id]
                            local img = nil
                            if store and store.cachedImagePath then
                                -- Read from cache
                                local data = Engine.readBinaryFile(store.cachedImagePath)
                                if data then
                                    img = {
                                        base64   = Engine.base64Encode(data),
                                        fileSize = #data,
                                    }
                                end
                            end
                            if not img then
                                -- Render fresh for beat casting
                                img = Engine.prepareImage(c.entry.photo,
                                    ts .. "_b" .. beatIdx .. "_" .. i,
                                    settings.provider, settings.renderSize)
                            end
                            if img then
                                images[#images + 1] = img
                                labels[#labels + 1] = string.format("[Photo %d]", #images)
                                validCandidates[#validCandidates + 1] = c
                            else
                                Logger.warn(string.format("  Beat %d: failed to render candidate %s",
                                    beatIdx, c.id))
                            end
                        end
                        -- Cap at 8 images per beat
                        if #images >= 8 then break end
                    end

                    if #images == 0 then
                        Logger.warn(string.format("  Beat %d: no renderable candidates", beatIdx))
                    elseif #images == 1 then
                        -- Only one candidate — auto-select
                        local c = validCandidates[1]
                        usedIds[c.id] = true
                        local e = c.entry
                        e.storyBeat     = beat.beat
                        e.storyRole     = beat.narrativeRole
                        e.storyNote     = beat.description
                        e.storyPosition = beat.position
                        finalSelection[#finalSelection + 1] = e
                        beatResults[beatIdx] = { primaryId = c.id }
                        previousSelections[#previousSelections + 1] = {
                            position = beat.position,
                            content  = c.content or "",
                        }
                        Logger.info(string.format("  Beat %d: auto-selected (only candidate) — %s",
                            beatIdx, (c.content or ""):sub(1, 60)))
                    else
                        -- Build and send vision prompt
                        local castPrompt = Engine.buildBeatCastingPrompt(
                            storyPrompt, beat.position, #beats,
                            beat.description or beat.beat,
                            beat.narrativeRole, beat.searchCriteria,
                            #images, previousSelections
                        )

                        local castResponse, castErr = Engine.queryVision(
                            images, labels, castPrompt, settings, 512)

                        local castResult = nil
                        if castResponse then
                            castResult, castErr = Engine.parseBeatCastingResponse(castResponse)
                        end

                        -- Select primary pick
                        local picked = false
                        if castResult and castResult.primary then
                            local priPos = castResult.primary
                            if priPos >= 1 and priPos <= #validCandidates then
                                local c = validCandidates[priPos]
                                if not usedIds[c.id] then
                                    usedIds[c.id] = true
                                    local e = c.entry
                                    e.storyBeat     = beat.beat
                                    e.storyRole     = beat.narrativeRole
                                    e.storyNote     = beat.description
                                    e.storyPosition = beat.position
                                    finalSelection[#finalSelection + 1] = e
                                    picked = true

                                    -- Record backup and flag
                                    local backupId = nil
                                    if castResult.backup and castResult.backup >= 1
                                       and castResult.backup <= #validCandidates then
                                        backupId = validCandidates[castResult.backup].id
                                    end
                                    beatResults[beatIdx] = {
                                        primaryId = c.id,
                                        backupId  = backupId,
                                        flag      = castResult.flag,
                                        reasoning = castResult.reasoning,
                                    }

                                    previousSelections[#previousSelections + 1] = {
                                        position = beat.position,
                                        content  = c.content or "",
                                    }
                                    Logger.info(string.format(
                                        "  Beat %d: vision selected #%d%s — %s",
                                        beatIdx, priPos,
                                        castResult.flag and (" [" .. castResult.flag .. "]") or "",
                                        (c.content or ""):sub(1, 60)))
                                end
                            end
                        end

                        -- Fallback: first unused candidate
                        if not picked then
                            Logger.warn(string.format("  Beat %d: vision casting failed (%s), using fallback",
                                beatIdx, castErr or "unknown"))
                            for _, c in ipairs(validCandidates) do
                                if not usedIds[c.id] then
                                    usedIds[c.id] = true
                                    local e = c.entry
                                    e.storyBeat     = beat.beat
                                    e.storyRole     = beat.narrativeRole
                                    e.storyNote     = beat.description
                                    e.storyPosition = beat.position
                                    finalSelection[#finalSelection + 1] = e
                                    beatResults[beatIdx] = { primaryId = c.id }
                                    previousSelections[#previousSelections + 1] = {
                                        position = beat.position,
                                        content  = c.content or "",
                                    }
                                    Logger.info(string.format("  Beat %d: fallback — %s",
                                        beatIdx, (c.content or ""):sub(1, 60)))
                                    break
                                end
                            end
                        end
                    end
                end
            end  -- beats in wave
        end  -- waves
    end  -- cloud vs ollama
    Logger.info("Pass 4 cost: " .. Engine.formatCostSummary())

    -- ── Pass 5: Story Review (vision) ─────────────────────────────────────
    -- Send final selection as images in story order for review.
    -- Skip for Ollama (too slow) or very small selections.
    if settings.provider ~= "ollama" and #finalSelection >= 5 then
        progress:setCaption("Pass 5: Reviewing story selection...")
        progress:setPortionComplete(7.5, 10)

        -- Sort by position for review
        table.sort(finalSelection, function(a, b)
            return (a.storyPosition or 0) < (b.storyPosition or 0)
        end)

        -- Batch review: up to 15 images per batch, 3-photo overlap
        local REVIEW_BATCH_SIZE = 15
        local REVIEW_OVERLAP    = 3
        local batchSummary = ""
        local allSwapRecs = {}

        local batchStart = 1
        while batchStart <= #finalSelection do
            local batchEnd = math.min(batchStart + REVIEW_BATCH_SIZE - 1, #finalSelection)

            -- Render images for this review batch
            local reviewImages = {}
            local reviewLabels = {}
            local ts = tostring(math.floor(LrDate.currentTime() * 1000))

            for i = batchStart, batchEnd do
                local e = finalSelection[i]
                local img = nil

                -- Try cached image
                local id = tostring(e.photo.localIdentifier)
                local store = photoStore[id]
                if store and store.cachedImagePath then
                    local data = Engine.readBinaryFile(store.cachedImagePath)
                    if data then
                        img = {
                            base64   = Engine.base64Encode(data),
                            fileSize = #data,
                        }
                    end
                end
                if not img then
                    img = Engine.prepareImage(e.photo, ts .. "_rev" .. i,
                        settings.provider, settings.renderSize)
                end
                if img then
                    reviewImages[#reviewImages + 1] = img
                    reviewLabels[#reviewLabels + 1] = string.format(
                        "[Photo %d — Beat: %s]", e.storyPosition or i,
                        (e.storyBeat or ""):sub(1, 40))
                end
            end

            if #reviewImages > 0 then
                local beatRange = string.format("%d-%d", batchStart, batchEnd)
                local reviewPrompt = Engine.buildStoryReviewPrompt(
                    storyPrompt, beats, beatRange, batchSummary)

                local reviewResponse, reviewErr = Engine.queryVision(
                    reviewImages, reviewLabels, reviewPrompt, settings, 2048)

                if reviewResponse then
                    local review, parseErr = Engine.parseStoryReviewResponse(reviewResponse)
                    if review then
                        batchSummary = review.batchSummary or ""
                        Logger.info(string.format("Pass 5: story coherence = %d/10. %s",
                            review.storyCoherence, review.coherenceNotes or ""))

                        -- Collect swap recommendations (deduplicate by position)
                        -- AI uses story positions from photo labels
                        local seenSwapPos = {}
                        for _, existing in ipairs(allSwapRecs) do
                            seenSwapPos[existing.position] = true
                        end
                        for _, swap in ipairs(review.swapRecommendations) do
                            if swap.position and not seenSwapPos[swap.position] then
                                seenSwapPos[swap.position] = true
                                allSwapRecs[#allSwapRecs + 1] = {
                                    position = swap.position,
                                    reason   = swap.reason,
                                    lookFor  = swap.look_for,
                                }
                            end
                        end

                        -- Log duplicates and gaps
                        if review.duplicates and #review.duplicates > 0 then
                            for _, dup in ipairs(review.duplicates) do
                                Logger.info(string.format("  Duplicate: positions %s — %s",
                                    table.concat(dup.positions or {}, ","), dup.description or ""))
                            end
                        end
                        if review.gaps and #review.gaps > 0 then
                            for _, gap in ipairs(review.gaps) do
                                Logger.info(string.format("  Gap: %s",
                                    gap.suggestion or gap.missing or ""))
                            end
                        end
                    else
                        Logger.warn("Pass 5: review parse failed: " .. (parseErr or "unknown"))
                    end
                else
                    Logger.warn("Pass 5: review call failed: " .. (reviewErr or "unknown"))
                end
            end

            -- Next batch with overlap
            if batchEnd >= #finalSelection then
                break  -- done
            end
            batchStart = batchEnd - REVIEW_OVERLAP + 1
        end

        -- ── Pass 6: Swap Resolution (vision) ─────────────────────────────
        -- One round of swaps only (no cascade).
        if #allSwapRecs > 0 then
            progress:setCaption("Pass 6: Resolving swaps...")
            progress:setPortionComplete(8.5, 10)
            Logger.info(string.format("Pass 6: %d swap recommendations to evaluate", #allSwapRecs))

            local swapCount = 0
            for _, swap in ipairs(allSwapRecs) do
                local selIdx = nil
                for i, e in ipairs(finalSelection) do
                    if (e.storyPosition or 0) == swap.position then
                        selIdx = i
                        break
                    end
                end
                if not selIdx then
                    Logger.warn(string.format("  Swap position %d: not found in selection", swap.position))
                else
                    local currentEntry = finalSelection[selIdx]
                    local currentId = tostring(currentEntry.photo.localIdentifier)

                    -- Find the beat for this position
                    local beatForSwap = nil
                    for _, b in ipairs(beats) do
                        if b.position == swap.position then beatForSwap = b; break end
                    end

                    -- Build replacement candidate list
                    local replacements = {}
                    -- Find the beat index (may differ from position if gaps exist)
                    local beatIdx = nil
                    for i, b in ipairs(beats) do
                        if b.position == swap.position then beatIdx = i; break end
                    end
                    beatIdx = beatIdx or swap.position  -- fallback
                    if beatResults[beatIdx] and beatResults[beatIdx].backupId
                       and not usedIds[beatResults[beatIdx].backupId] then
                        -- Find the candidate entry for the backup
                        for _, c in ipairs(candidatesByBeat[beatIdx] or {}) do
                            if c.id == beatResults[beatIdx].backupId then
                                replacements[#replacements + 1] = c
                                break
                            end
                        end
                    end
                    -- Then: other unused candidates for this beat
                    for _, c in ipairs(candidatesByBeat[beatIdx] or {}) do
                        if c.id ~= currentId and not usedIds[c.id] then
                            local isDup = false
                            for _, r in ipairs(replacements) do
                                if r.id == c.id then isDup = true; break end
                            end
                            if not isDup then
                                replacements[#replacements + 1] = c
                            end
                        end
                        if #replacements >= 4 then break end
                    end

                    if #replacements == 0 then
                        Logger.info(string.format("  Swap position %d: no replacement candidates", swap.position))
                    else
                        -- Render current + replacements
                        local swapImages = {}
                        local swapLabels = {}
                        local ts = tostring(math.floor(LrDate.currentTime() * 1000))

                        -- Current photo is Photo 1
                        local store = photoStore[currentId]
                        local currentImg = nil
                        if store and store.cachedImagePath then
                            local data = Engine.readBinaryFile(store.cachedImagePath)
                            if data then
                                currentImg = {
                                    base64   = Engine.base64Encode(data),
                                    fileSize = #data,
                                }
                            end
                        end
                        if not currentImg then
                            currentImg = Engine.prepareImage(currentEntry.photo,
                                ts .. "_swap_cur", settings.provider, settings.renderSize)
                        end
                        if currentImg then
                            swapImages[#swapImages + 1] = currentImg
                            swapLabels[#swapLabels + 1] = "[Photo 1 — CURRENT]"
                        end

                        -- Replacement photos
                        local validReplacements = {}
                        for i, r in ipairs(replacements) do
                            local rImg = nil
                            local rStore = photoStore[r.id]
                            if rStore and rStore.cachedImagePath then
                                local data = Engine.readBinaryFile(rStore.cachedImagePath)
                                if data then
                                    rImg = {
                                        base64   = Engine.base64Encode(data),
                                        fileSize = #data,
                                    }
                                end
                            end
                            if not rImg then
                                rImg = Engine.prepareImage(r.entry.photo,
                                    ts .. "_swap_r" .. i, settings.provider, settings.renderSize)
                            end
                            if rImg then
                                swapImages[#swapImages + 1] = rImg
                                swapLabels[#swapLabels + 1] = string.format("[Photo %d — REPLACEMENT]", #swapImages)
                                validReplacements[#validReplacements + 1] = r
                            end
                        end

                        if #swapImages >= 2 then
                            local swapPrompt = Engine.buildSwapResolutionPrompt(
                                storyPrompt, swap.position,
                                beatForSwap and (beatForSwap.description or beatForSwap.beat) or "",
                                swap.reason, swap.lookFor, #validReplacements)

                            local swapResponse, swapErr = Engine.queryVision(
                                swapImages, swapLabels, swapPrompt, settings, 512)

                            if swapResponse then
                                local swapResult, parseErr = Engine.parseSwapResolutionResponse(swapResponse)
                                if swapResult and swapResult.action == "swap" and swapResult.replacement then
                                    -- replacement index is 2-based (1 is current)
                                    local repIdx = swapResult.replacement - 1
                                    if repIdx >= 1 and repIdx <= #validReplacements then
                                        local newC = validReplacements[repIdx]
                                        -- Perform swap
                                        usedIds[currentId] = nil
                                        usedIds[newC.id] = true
                                        local e = newC.entry
                                        e.storyBeat     = currentEntry.storyBeat
                                        e.storyRole     = currentEntry.storyRole
                                        e.storyNote     = currentEntry.storyNote
                                        e.storyPosition = currentEntry.storyPosition
                                        finalSelection[selIdx] = e
                                        swapCount = swapCount + 1
                                        Logger.info(string.format(
                                            "  Swap position %d: replaced with %s — %s",
                                            swap.position, newC.id,
                                            (swapResult.reasoning or ""):sub(1, 80)))
                                    end
                                else
                                    Logger.info(string.format("  Swap position %d: keeping current — %s",
                                        swap.position, (swapResult and swapResult.reasoning or ""):sub(1, 80)))
                                end
                            else
                                Logger.warn(string.format("  Swap position %d: vision call failed: %s",
                                    swap.position, swapErr or "unknown"))
                            end
                        end
                    end
                end
            end
            Logger.info(string.format("Pass 6: %d swaps applied of %d recommended",
                swapCount, #allSwapRecs))
        end
    else
        if settings.provider == "ollama" then
            Logger.info("Passes 5-6: skipped (Ollama)")
        else
            Logger.info("Passes 5-6: skipped (selection too small)")
        end
    end

    -- ── Final sort and return ─────────────────────────────────────────────
    table.sort(finalSelection, function(a, b)
        return (a.storyPosition or 0) < (b.storyPosition or 0)
    end)

    Logger.info(string.format("v3 Story: selected %d photos for %d beats",
        #finalSelection, #beats))
    Logger.info("Total pipeline cost: " .. Engine.formatCostSummary())

    -- Clean up cached image files
    local cleanedUp = 0
    for id, store in pairs(photoStore) do
        if store.cachedImagePath then
            Engine.safeDelete(store.cachedImagePath)
            store.cachedImagePath = nil
            cleanedUp = cleanedUp + 1
        end
    end
    if cleanedUp > 0 then
        Logger.info(string.format("Image cache: cleaned up %d temp files", cleanedUp))
    end

    return finalSelection, nil
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

    -- Reset cost tracker for selection phase (scoring has its own tracker)
    Engine.resetCostTracker()

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

    -- ── Build photoStore: central in-memory data for all passes ─────────
    -- Indexed by localIdentifier. Single source of truth for Passes 2-6.
    -- Populated once here; downstream passes reference it, never re-read LR metadata.
    local photoStore = {}
    for _, e in ipairs(scored) do
        local id = e.photo.localIdentifier
        local captureTime = e.photo:getRawMetadata('dateTimeOriginal')

        -- Read EXIF data
        local exifParts = {}
        local isoVal = e.photo:getRawMetadata('isoSpeedRating')
        if isoVal then exifParts[#exifParts + 1] = "ISO " .. tostring(isoVal) end
        local shutterVal = e.photo:getFormattedMetadata('shutterSpeed')
        if shutterVal and shutterVal ~= "" then exifParts[#exifParts + 1] = shutterVal end
        local apertureVal = e.photo:getFormattedMetadata('aperture')
        if apertureVal and apertureVal ~= "" then exifParts[#exifParts + 1] = apertureVal end
        local focalVal = e.photo:getFormattedMetadata('focalLength')
        if focalVal and focalVal ~= "" then exifParts[#exifParts + 1] = focalVal end

        photoStore[id] = {
            photo        = e.photo,
            filename     = e.photo:getFormattedMetadata('fileName'),
            scores       = {
                technical   = e.technical,
                composition = e.composition,
                emotion     = e.emotion,
                moment      = e.moment,
            },
            composite    = e.compositeScore,
            content      = e.content,
            category     = e.category,
            eyeQuality   = e.eyeQuality,
            reject       = e.reject,
            captureTime  = captureTime,
            exif         = #exifParts > 0 and table.concat(exifParts, ", ") or nil,
            people       = {},   -- populated by face query later
            batchIndex   = nil,  -- populated during story mode if snapshots available
            cachedImagePath = nil,  -- populated when image cache is built (Passes 4-6)
        }
    end

    -- Populate people data from face query (once, upfront)
    local allPhotos = {}
    for _, e in ipairs(scored) do allPhotos[#allPhotos + 1] = e.photo end
    local faceMap = Engine.queryFacePeople(catalog, allPhotos)
    if faceMap then
        for id, store in pairs(photoStore) do
            local names = faceMap[id]
            if names then store.people = names end
        end
        Logger.info("Face data loaded for photoStore")
    else
        Logger.info("Face query unavailable — photoStore.people will be empty")
    end

    Logger.info("photoStore built: " .. tostring(totalScored) .. " entries")

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
    progress:setPortionComplete(2.5, 10)
    local afterPhashDedup, phashDupCount = deduplicateByPhash(afterTimestampDedup)

    -- Step 2c: Deduplicate by content description (near-duplicate detection)
    progress:setCaption("Removing content duplicates...")
    progress:setPortionComplete(3, 10)
    local afterDedup, contentDupCount = deduplicateByContent(afterPhashDedup)

    -- ── Mode dispatch ─────────────────────────────────────────────────────
    progress:setPortionComplete(4, 10)

    local selected
    local groupOrder = {}
    local storyFallback = false
    local gapsFilled = 0
    if mode == "story" then
        -- v3 story pipeline: use selectStoryV3 when user confirmed a story prompt
        if SETTINGS.storyPrompt and SETTINGS.storyPrompt ~= "" then
            Logger.info("Story mode: using v3 multi-pass pipeline")
            progress:setCaption("Building story (Pass 2-3)...")
            local storySelected, storyErr = selectStoryV3(
                afterDedup, SETTINGS, catalog, snapshots, photoStore, progress)
            if storySelected then
                selected = storySelected
            else
                Logger.warn("Story v3 failed: " .. tostring(storyErr) .. " — falling back to Best Of")
                storyFallback = true
                selected, groupOrder = selectBestOf(afterDedup, SETTINGS)
            end
        else
            -- v2 fallback: no story prompt means user didn't go through mid-run dialog
            Logger.info("Story mode: using v2 pipeline (no story prompt)")
            progress:setCaption("Querying AI for narrative selection...")
            local storySelected, storyErr, storyGaps = selectStory(
                afterDedup, SETTINGS, catalog, snapshots, progress)
            if storySelected then
                selected = storySelected
                gapsFilled = storyGaps or 0
            else
                Logger.warn("Story mode failed: " .. tostring(storyErr) .. " — falling back to Best Of")
                storyFallback = true
                selected, groupOrder = selectBestOf(afterDedup, SETTINGS)
            end
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
    if contentDupCount > 0 then
        lines[#lines + 1] = string.format("%d content duplicates removed (description similarity)", contentDupCount)
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

    -- Cost summary (selection passes only — does not include Pass 1 scoring)
    local costSummary = Engine.getCostSummary()
    if costSummary.callCount > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Selection cost: " .. Engine.formatCostSummary()
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
