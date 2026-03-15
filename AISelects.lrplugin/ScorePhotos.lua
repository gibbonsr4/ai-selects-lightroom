--[[
  ScorePhotos.lua
  ---------------------------------------------------------------------------
  Pass 1: Batch scoring pipeline.

  Sorts selected photos chronologically, forms batches, sends multi-image
  API calls with carryover anchors, writes 4-dimension scores + metadata,
  extracts story snapshots.

  Can be invoked directly (menu item) or via ScoreAndSelect.lua which
  calls the exported runScoring(context, config) function.

  v2: Replaces single-image scoring with relative batch ranking.
  macOS only.
--]]

-- == LR SDK imports ===========================================================
local LrApplication     = import 'LrApplication'
local LrDate            = import 'LrDate'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils       = import 'LrPathUtils'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'

local Engine        = dofile(_PLUGIN.path .. '/AIEngine.lua')
local Prefs         = dofile(_PLUGIN.path .. '/Prefs.lua')
local BatchStrategy = dofile(_PLUGIN.path .. '/BatchStrategy.lua')

-- == Logger ===================================================================
-- Writes incrementally so crash mid-run still captures everything up to that point.
local Logger = {}

function Logger:init(settings)
    self.enabled = settings.enableLogging
    self.fileHandle = nil
    self.startTime = LrDate.currentTime()
    self.initError = nil
    if not self.enabled then return end

    local LrFileUtils = import 'LrFileUtils'
    local timestamp = LrDate.timeToUserFormat(self.startTime, "%Y-%m-%d_%H-%M-%S")
    local folder = settings.logFolder
    if not folder or folder == "" then
        folder = LrPathUtils.getStandardFilePath('documents')
    end

    if not LrFileUtils.exists(folder) then
        local fallback = LrPathUtils.getStandardFilePath('documents')
        if LrFileUtils.exists(fallback) then
            folder = fallback
        end
    end

    local logName = "AI_Selects_Score_" .. timestamp .. ".log"
    self.filePath = LrPathUtils.child(folder, logName)

    local fh, openErr = io.open(self.filePath, "w")
    if not fh then
        self.initError = "Could not create log file: " .. tostring(openErr)
            .. "\nPath: " .. self.filePath
        self.enabled = false
        return
    end
    self.fileHandle = fh

    self:log("===================================================================")
    self:log("AI Selects v2 - Batch Scoring started at "
        .. LrDate.timeToUserFormat(self.startTime, "%Y-%m-%d %H:%M:%S"))
    self:log("Provider: " .. settings.provider)
    if settings.provider == "ollama" then
        self:log("Model: " .. settings.model)
        self:log("Ollama URL: " .. settings.ollamaUrl)
    elseif settings.provider == "claude" then
        self:log("Model: " .. settings.claudeModel)
    elseif settings.provider == "openai" then
        self:log("Model: " .. settings.openaiModel)
    elseif settings.provider == "gemini" then
        self:log("Model: " .. settings.geminiModel)
    end
    self:log("Render size: " .. tostring(settings.renderSize) .. "px")
    self:log("Nitpicky scale: " .. tostring(settings.nitpickyScale))
    self:log("Batch size: " .. tostring(BatchStrategy.getBatchSize(settings.provider, settings.batchSize)))
    self:log("Skip scored: " .. tostring(settings.skipScored))
    self:log("===================================================================")
end

function Logger:_writeRaw(text)
    if self.fileHandle then
        self.fileHandle:write(text)
        self.fileHandle:flush()
    end
end

function Logger:log(message)
    if not self.enabled then return end
    local ts = LrDate.timeToUserFormat(LrDate.currentTime(), "%H:%M:%S")
    local line = ts .. "  " .. message .. "\n"
    self:_writeRaw(line)
end

function Logger:logBatch(batchNum, totalBatches, photoCount, detail)
    if not self.enabled then return end
    self:log(string.format("[Batch %d/%d] %d photos  %s", batchNum, totalBatches, photoCount, detail))
end

function Logger:finish(successCount, errorCount, skippedCount, batchCount)
    if not self.enabled then return end
    local elapsed = LrDate.currentTime() - self.startTime
    self:log("===================================================================")
    self:log(string.format("Run complete - %d scored in %d batches, %d errors, %d skipped (%.0fs elapsed)",
        successCount, batchCount or 0, errorCount, skippedCount, elapsed))
    self:log("===================================================================")

    if self.fileHandle then
        self.fileHandle:close()
        self.fileHandle = nil
    end
end

-- == Write scores to custom metadata ==========================================
-- Writes all 4 dimensions + composite + descriptive fields for one photo.
local function writeScores(catalog, photo, scores, composite, phash, batchId, filename)
    local writeResult = catalog:withWriteAccessDo(
        "AI Selects - Score " .. filename,
        function()
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsTechnical',    tostring(scores.technical))
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsComposition',  tostring(scores.composition))
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsEmotion',      tostring(scores.emotion))
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsMoment',       tostring(scores.moment))
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsComposite',    string.format("%.1f", composite))
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsContent',      scores.content)
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsCategory',     scores.category)
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsReject',       tostring(scores.reject))
            if scores.eye_quality then
                photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsEyeQuality', scores.eye_quality)
            end
            -- narrative_role NOT written during Pass 1 scoring.
            -- Assigned during story assembly (Pass 2) when full context is available.
            if phash then
                photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsPhash', phash)
            end
            if batchId then
                photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsBatchId', tostring(batchId))
            end
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate',
                LrDate.timeToUserFormat(LrDate.currentTime(), "%Y-%m-%d %H:%M:%S"))
        end,
        { timeout = 10 }
    )
    return writeResult
end

-- == Shared setup: validate photos, API keys, filter file types ===============
-- Returns (SETTINGS, catalog, toProcess, skipped) or nil on error/cancel.
local function validateAndPrepare(configOverride)
    local SETTINGS = Prefs.getPrefs()
    -- Merge run dialog overrides on top of full settings
    if configOverride then
        for k, v in pairs(configOverride) do
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

    -- Validate API keys
    if SETTINGS.provider == "claude" and (SETTINGS.claudeApiKey == nil or SETTINGS.claudeApiKey == "") then
        LrDialogs.message("AI Selects",
            "Claude API selected but no API key configured.\n\nOpen Settings and enter your Anthropic API key.", "warning")
        return nil
    end
    if SETTINGS.provider == "openai" and (SETTINGS.openaiApiKey == nil or SETTINGS.openaiApiKey == "") then
        LrDialogs.message("AI Selects",
            "OpenAI API selected but no API key configured.\n\nOpen Settings and enter your OpenAI API key.", "warning")
        return nil
    end
    if SETTINGS.provider == "gemini" and (SETTINGS.geminiApiKey == nil or SETTINGS.geminiApiKey == "") then
        LrDialogs.message("AI Selects",
            "Gemini API selected but no API key configured.\n\nOpen Settings and enter your Google AI API key.", "warning")
        return nil
    end

    -- Split into processable vs unsupported
    local toProcess, skipped = {}, {}
    for _, photo in ipairs(targetPhotos) do
        local path = photo:getRawMetadata('path')
        if Engine.SUPPORTED_EXTS[Engine.getExt(path)] then
            toProcess[#toProcess + 1] = photo
        else
            skipped[#skipped + 1] = LrPathUtils.leafName(path)
        end
    end

    if #toProcess == 0 then
        LrDialogs.message("AI Selects - Skipped",
            "No supported files found.\n\n" ..
            "Supported: JPEG, PNG, TIFF, WEBP, HEIC, RAW (CR2, CR3, NEF, ARW, DNG, etc.)\n\n" ..
            "Skipped: " .. table.concat(skipped, ", "):sub(1, 200), "warning")
        return nil
    end

    -- Clean up orphaned temp files from interrupted runs
    LrTasks.execute("rm -f /tmp/ai_sel_req_* /tmp/ai_sel_resp_* /tmp/ai_sel_cfg_* 2>/dev/null")

    return SETTINGS, catalog, toProcess, skipped
end

-- == Provider display info ====================================================
local function getProviderInfo(SETTINGS)
    local modelName
    if SETTINGS.provider == "claude" then
        modelName = SETTINGS.claudeModel
    elseif SETTINGS.provider == "openai" then
        modelName = SETTINGS.openaiModel
    elseif SETTINGS.provider == "gemini" then
        modelName = SETTINGS.geminiModel
    else
        modelName = SETTINGS.model
    end
    local providerLabels = {
        claude = "Claude API", openai = "OpenAI API",
        gemini = "Gemini API", ollama = "Ollama",
    }
    local providerLabel = providerLabels[SETTINGS.provider] or "Ollama"
    return providerLabel, modelName or "unknown"
end

-- == Core batch scoring logic =================================================
-- @param context       LrFunctionContext
-- @param config        Optional settings override (from ScoreAndSelect.lua)
-- @return (successCount, errorCount, skippedCount, summary, snapshots) or nil
local function runScoring(context, config)
    local SETTINGS, catalog, toProcess, skipped = validateAndPrepare(config)
    if not SETTINGS then return nil end

    local providerLabel, modelName = getProviderInfo(SETTINGS)
    local provider = SETTINGS.provider
    local includeSnapshots = BatchStrategy.supportsSnapshots(provider)
    local weights = BatchStrategy.computeWeights(SETTINGS.emphasisSlider)

    -- Initialize logger
    local log = setmetatable({}, { __index = Logger })
    log:init(SETTINGS)

    -- Filter already-scored photos if skipScored is enabled
    local photosToScore = {}
    local skippedScored = 0
    for _, photo in ipairs(toProcess) do
        if SETTINGS.skipScored then
            local scoreDate = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate')
            if scoreDate and scoreDate ~= "" then
                skippedScored = skippedScored + 1
                local fn = LrPathUtils.leafName(photo:getRawMetadata('path'))
                log:log("[SKIP]  " .. fn .. "  ->  already scored on " .. scoreDate)
            else
                photosToScore[#photosToScore + 1] = photo
            end
        else
            photosToScore[#photosToScore + 1] = photo
        end
    end

    if #photosToScore == 0 then
        log:finish(0, 0, skippedScored, 0)
        return 0, 0, skippedScored, "All photos already scored. Nothing to do."
    end

    -- Form chronological batches
    local batches = BatchStrategy.formBatches(photosToScore, provider, SETTINGS.batchSize)
    local totalBatches = #batches

    log:log(string.format("Scoring %d photos in %d batches (batch size: %d)",
        #photosToScore, totalBatches,
        BatchStrategy.getBatchSize(provider, SETTINGS.batchSize)))

    -- ── Capture time continuity check ────────────────────────────────────
    -- Warn about missing times and large gaps that may affect scoring quality.
    do
        local noTimeCount = 0
        local captureTimes = {}
        -- Flatten batches to get chronological order
        for _, batch in ipairs(batches) do
            for _, photo in ipairs(batch) do
                local ct = photo:getRawMetadata('dateTimeOriginal')
                if ct then
                    captureTimes[#captureTimes + 1] = ct
                else
                    noTimeCount = noTimeCount + 1
                end
            end
        end

        if noTimeCount > 0 then
            log:log(string.format("⚠ %d of %d photos have no capture time — "
                .. "these will sort to the end and may reduce scoring/story quality.",
                noTimeCount, #photosToScore))
        end

        -- Check for large time gaps (>4 hours) that might indicate mixed shoots
        if #captureTimes >= 2 then
            table.sort(captureTimes)
            local gaps = {}
            for i = 2, #captureTimes do
                local gapSecs = captureTimes[i] - captureTimes[i - 1]
                if gapSecs > 14400 then  -- 4 hours
                    local gapHours = math.floor(gapSecs / 3600)
                    local t1 = LrDate.timeToUserFormat(captureTimes[i - 1], "%Y-%m-%d %H:%M")
                    local t2 = LrDate.timeToUserFormat(captureTimes[i], "%Y-%m-%d %H:%M")
                    gaps[#gaps + 1] = string.format("%dh gap: %s → %s", gapHours, t1, t2)
                end
            end
            if #gaps > 0 then
                log:log(string.format("⚠ %d large time gap(s) detected — "
                    .. "this may span multiple shoots or days:", #gaps))
                for _, g in ipairs(gaps) do
                    log:log("  " .. g)
                end
                log:log("  This is normal for multi-day trips but may affect batch continuity.")
            end
        end
    end

    -- Reset cost tracker for this run
    Engine.resetCostTracker()

    -- Track results
    local successCount = 0
    local errorLog = {}
    local allSnapshots = {}  -- collected for story mode
    local allScores = {      -- per-dimension arrays for distribution stats
        technical = {}, composition = {}, emotion = {}, moment = {}, composite = {},
    }

    -- Carryover state
    local previousBatchScores = nil
    local startTime = LrDate.currentTime()

    -- == Main batch loop ======================================================
    local progress = LrProgressScope({
        title           = "AI Selects (" .. providerLabel .. " - " .. modelName .. ")",
        functionContext = context,
    })

    for batchIdx, batch in ipairs(batches) do repeat  -- repeat/until true = breakable block
        if progress:isCanceled() then
            log:log("Run canceled by user at batch " .. batchIdx)
            break
        end

        -- ETA calculation
        local eta = ""
        if batchIdx > 1 then
            local elapsed = LrDate.currentTime() - startTime
            local avgBatch = elapsed / (batchIdx - 1)
            local remaining = avgBatch * (totalBatches - batchIdx + 1)
            eta = string.format(" — ~%d min remaining", math.ceil(remaining / 60))
        end

        local firstPhoto = batchIdx == 1 and 1 or 0
        local photoRangeStart = 0
        for b = 1, batchIdx - 1 do photoRangeStart = photoRangeStart + #batches[b] end
        photoRangeStart = photoRangeStart + 1
        local photoRangeEnd = photoRangeStart + #batch - 1

        progress:setPortionComplete(batchIdx - 1, totalBatches)
        progress:setCaption(string.format("[Batch %d/%d] Scoring photos %d-%d%s",
            batchIdx, totalBatches, photoRangeStart, photoRangeEnd, eta))

        log:logBatch(batchIdx, totalBatches, #batch, "Starting")

        -- 1. Prepare images for this batch
        local images = {}
        local imageLabels = {}
        local photoIds = {}
        local photoTimestamps = {}
        local photoExifData = {}
        -- Positional lookup: maps 1-based index in images array → { photo, filename, id, exif }
        local photoByPosition = {}
        local renderErrors = {}

        for i, photo in ipairs(batch) do
            local path = photo:getRawMetadata('path')
            local filename = LrPathUtils.leafName(path)
            local id = tostring(photo.localIdentifier)
            local captureTime = photo:getRawMetadata('dateTimeOriginal')
            local timestamp = ""
            if captureTime then
                timestamp = LrDate.timeToUserFormat(captureTime, "%Y-%m-%d %H:%M:%S")
            end

            -- Read EXIF data for scoring context
            local exifParts = {}
            local isoVal = photo:getRawMetadata('isoSpeedRating')
            if isoVal then exifParts[#exifParts + 1] = "ISO " .. tostring(isoVal) end
            local shutterVal = photo:getFormattedMetadata('shutterSpeed')
            if shutterVal and shutterVal ~= "" then exifParts[#exifParts + 1] = shutterVal end
            local apertureVal = photo:getFormattedMetadata('aperture')
            if apertureVal and apertureVal ~= "" then exifParts[#exifParts + 1] = apertureVal end
            local focalVal = photo:getFormattedMetadata('focalLength')
            if focalVal and focalVal ~= "" then exifParts[#exifParts + 1] = focalVal end
            local exifStr = #exifParts > 0 and table.concat(exifParts, ", ") or nil

            local ts = tostring(math.floor(LrDate.currentTime() * 1000))
                .. "_b" .. batchIdx .. "_" .. i
            local img, err = Engine.prepareImage(photo, ts, provider, SETTINGS.renderSize)

            if img then
                local pos = #images + 1
                images[pos] = img
                imageLabels[pos] = string.format("Photo %d of %d", pos, #batch)
                photoIds[#photoIds + 1] = id
                photoTimestamps[#photoTimestamps + 1] = timestamp
                photoExifData[#photoExifData + 1] = exifStr or ""
                photoByPosition[pos] = { photo = photo, filename = filename, id = id, exif = exifStr }
            else
                renderErrors[#renderErrors + 1] = filename .. ": " .. (err or "render failed")
                log:log("  [FAIL]  " .. filename .. "  ->  " .. (err or "render failed"))
                errorLog[#errorLog + 1] = "- " .. filename .. "\n  " .. (err or "render failed")
            end
        end

        if #images == 0 then
            log:logBatch(batchIdx, totalBatches, #batch, "All renders failed, skipping")
            break  -- skip to next batch
        end

        -- 2. Select carryover anchors from previous batch
        local anchors = BatchStrategy.selectAnchors(previousBatchScores, provider)
        local anchorImages = nil
        local anchorLabels = nil

        if #anchors > 0 and provider ~= "ollama" then
            -- For cloud providers: render anchor images and include them
            anchorImages = {}
            anchorLabels = {}
            for ai, anchor in ipairs(anchors) do
                local ats = tostring(math.floor(LrDate.currentTime() * 1000))
                    .. "_anc_" .. batchIdx .. "_" .. ai
                local aImg, aErr = Engine.prepareImage(anchor.photo, ats, provider, SETTINGS.renderSize)
                if aImg then
                    anchorImages[#anchorImages + 1] = aImg
                    anchorLabels[#anchorLabels + 1] = string.format(
                        "ANCHOR %d (%s) — DO NOT SCORE. Prior: T=%d C=%d E=%d M=%d (%.1f)",
                        ai, anchor.role,
                        anchor.scores.technical, anchor.scores.composition,
                        anchor.scores.emotion, anchor.scores.moment,
                        anchor.composite
                    )
                else
                    log:log(string.format("  Anchor %d render failed: %s", ai, aErr or "unknown"))
                end
            end
            if #anchorImages == 0 then
                anchorImages = nil
                anchorLabels = nil
            end
        end

        -- 3. Build the scoring prompt (pass prior snapshots for narrative context)
        local prompt = Engine.buildBatchScoringPrompt(
            photoIds, photoTimestamps, photoExifData, anchors,
            SETTINGS.nitpickyScale, includeSnapshots, SETTINGS.preHints, allSnapshots
        )

        log:log(string.format("  Prompt length: %d chars, %d images + %d anchors",
            #prompt, #images, anchorImages and #anchorImages or 0))

        -- 4. Send batch API call
        local queryStart = LrDate.currentTime()
        local maxTokens = BatchStrategy.getMaxTokens(provider, "scoring")
        local rawResponse, queryErr, stopReason = Engine.queryBatch(
            images, imageLabels, anchorImages, anchorLabels,
            prompt, SETTINGS, maxTokens
        )
        local queryElapsed = LrDate.currentTime() - queryStart

        log:log(string.format("  Query time: %.1fs", queryElapsed))

        if stopReason then
            log:log("  Stop reason: " .. tostring(stopReason))
        end

        if not rawResponse then
            log:logBatch(batchIdx, totalBatches, #batch, "API error: " .. (queryErr or "unknown"))
            for pos = 1, #images do
                local info = photoByPosition[pos]
                if info then
                    errorLog[#errorLog + 1] = "- " .. info.filename .. "\n  Batch API error: " .. (queryErr or "unknown")
                end
            end
            break  -- skip to next batch
        end

        if log.enabled then
            log:log("  Raw response (first 800): " .. rawResponse:sub(1, 800))
        end

        -- 5. Parse batch response (positional — no ID matching needed)
        local batchScores, snapshot, parseMsg = Engine.parseBatchResponse(rawResponse, stopReason)

        if not batchScores then
            log:logBatch(batchIdx, totalBatches, #batch, "Parse error: " .. (parseMsg or "unknown"))
            for pos = 1, #images do
                local info = photoByPosition[pos]
                if info then
                    errorLog[#errorLog + 1] = "- " .. info.filename .. "\n  " .. (parseMsg or "Parse error")
                end
            end
            break  -- skip to next batch
        end

        -- Log warnings (e.g., partial recovery from truncation)
        if parseMsg then
            log:log("  ⚠ " .. parseMsg)
        end

        -- Validate score count matches photo count
        if #batchScores ~= #images then
            log:log(string.format("  Warning: got %d scores for %d photos", #batchScores, #images))
        end

        log:log(string.format("  Parsed %d scores%s",
            #batchScores, snapshot and " + snapshot" or ""))
        log:log("  Cost so far: " .. Engine.formatCostSummary())

        -- 6. Store snapshot (if present)
        if snapshot then
            snapshot.batchIndex = batchIdx
            snapshot.photoIds = photoIds
            -- Add time range from first/last photo in batch
            if #photoTimestamps > 0 then
                snapshot.timeRange = {
                    start = photoTimestamps[1],
                    finish = photoTimestamps[#photoTimestamps],
                }
            end
            allSnapshots[#allSnapshots + 1] = snapshot
            log:log("  Snapshot: " .. tostring(snapshot.scene or ""):sub(1, 300))
        end

        -- 7. Write scores to metadata — POSITIONAL mapping (score[i] → photo[i])
        local batchScoreEntries = {}  -- for carryover anchor selection
        local scoreCount = math.min(#batchScores, #images)
        for pos = 1, scoreCount do repeat  -- repeat/until true = breakable block
            local scoreEntry = batchScores[pos]
            local info = photoByPosition[pos]
            if not info then
                log:log("  Warning: no photo at position " .. pos)
                break
            end

            local photo = info.photo
            local filename = info.filename
            local id = info.id

            -- Compute composite score
            local composite = BatchStrategy.computeComposite(
                { technical = scoreEntry.technical, composition = scoreEntry.composition,
                  emotion = scoreEntry.emotion, moment = scoreEntry.moment },
                weights, scoreEntry.eye_quality
            )

            -- Compute perceptual hash for visual duplicate detection
            local phash = nil
            local phashTs = tostring(batchIdx) .. "_" .. tostring(pos)
            local hashVal, hashErr = Engine.computePhash(photo, phashTs)
            if hashVal then
                phash = hashVal
                log:log("  Phash for " .. filename .. ": " .. hashVal)
            else
                log:log("  Phash skipped for " .. filename .. ": " .. tostring(hashErr))
            end

            -- Write to catalog
            LrTasks.yield()
            local writeResult = writeScores(
                catalog, photo, scoreEntry, composite, phash, batchIdx, filename)
            LrTasks.yield()

            local writeOk = (writeResult == "executed")
            local writeErr = not writeOk
                and ("Catalog write not executed (result: " .. tostring(writeResult) .. ")") or nil

            if writeOk then
                successCount = successCount + 1
                allScores.technical[#allScores.technical + 1] = scoreEntry.technical
                allScores.composition[#allScores.composition + 1] = scoreEntry.composition
                allScores.emotion[#allScores.emotion + 1] = scoreEntry.emotion
                allScores.moment[#allScores.moment + 1] = scoreEntry.moment
                allScores.composite[#allScores.composite + 1] = composite

                -- Build entry for carryover
                batchScoreEntries[#batchScoreEntries + 1] = {
                    photo     = photo,
                    id        = id,
                    technical   = scoreEntry.technical,
                    composition = scoreEntry.composition,
                    emotion     = scoreEntry.emotion,
                    moment      = scoreEntry.moment,
                    composite   = composite,
                    content     = scoreEntry.content,
                }

                local eyeStr = (scoreEntry.eye_quality and scoreEntry.eye_quality ~= "na")
                    and (" Eye:" .. scoreEntry.eye_quality) or ""
                log:log(string.format("  [OK]    %s  ->  T:%d C:%d E:%d M:%d (%.1f) Cat:%s %s%s%s",
                    filename,
                    scoreEntry.technical, scoreEntry.composition,
                    scoreEntry.emotion, scoreEntry.moment, composite,
                    scoreEntry.category, scoreEntry.content,
                    eyeStr, scoreEntry.reject and " [REJECT]" or ""))
            else
                errorLog[#errorLog + 1] = "- " .. filename .. "\n  Write error: " .. tostring(writeErr)
                log:log("  [FAIL]  " .. filename .. "  ->  Write failed: " .. tostring(writeErr))
            end

        until true end  -- end repeat block, end score loop

        -- Update carryover for next batch
        previousBatchScores = batchScoreEntries

        log:logBatch(batchIdx, totalBatches, #batch,
            string.format("Done: %d scored, %d errors", #batchScoreEntries, #renderErrors))

        LrTasks.sleep(0.05)
    until true end  -- end repeat block, end for loop

    progress:setPortionComplete(1, 1)
    progress:done()

    -- == Log score distributions ==============================================
    local function logDimensionStats(name, arr)
        if #arr == 0 then return end
        local mn, mx, sum = 10, 1, 0
        for _, v in ipairs(arr) do
            if v < mn then mn = v end
            if v > mx then mx = v end
            sum = sum + v
        end
        log:log(string.format("  %s: %d - %d (mean %.1f)", name, mn, mx, sum / #arr))
    end

    if #allScores.technical > 0 then
        log:log("Score distributions (" .. #allScores.technical .. " photos):")
        logDimensionStats("Technical", allScores.technical)
        logDimensionStats("Composition", allScores.composition)
        logDimensionStats("Emotion", allScores.emotion)
        logDimensionStats("Moment", allScores.moment)
        logDimensionStats("Composite", allScores.composite)
    end

    if #allSnapshots > 0 then
        log:log(string.format("Story snapshots collected: %d", #allSnapshots))
        for _, snap in ipairs(allSnapshots) do
            log:log(string.format("  Batch %d: %s", snap.batchIndex or 0,
                tostring(snap.scene or ""):sub(1, 300)))
        end
    end

    log:finish(successCount, #errorLog, skippedScored, totalBatches)

    -- == Build completion summary =============================================
    local elapsed = LrDate.currentTime() - startTime
    local lines = { string.format("%d photo(s) scored in %d batches via %s (%.0fs elapsed)",
        successCount, totalBatches, providerLabel, elapsed) }

    if skippedScored > 0 then
        lines[#lines + 1] = string.format("%d photo(s) skipped (already scored)", skippedScored)
    end
    if #skipped > 0 then
        lines[#lines + 1] = string.format("%d file(s) skipped (unsupported format)", #skipped)
    end
    if #errorLog > 0 then
        lines[#lines + 1] = string.format("%d error(s):\n%s",
            #errorLog, table.concat(errorLog, "\n"):sub(1, 1200))
    end

    -- Score distribution breakdown
    if #allScores.technical > 0 then
        local function dimStats(arr)
            local mn, mx, sum = 10, 1, 0
            for _, v in ipairs(arr) do
                if v < mn then mn = v end
                if v > mx then mx = v end
                sum = sum + v
            end
            return mn, mx, sum / #arr
        end

        local tMin, tMax, tMean = dimStats(allScores.technical)
        local cMin, cMax, cMean = dimStats(allScores.composition)
        local eMin, eMax, eMean = dimStats(allScores.emotion)
        local mMin, mMax, mMean = dimStats(allScores.moment)

        lines[#lines + 1] = "\n-- Score Distribution --"
        lines[#lines + 1] = string.format("Technical:    %d - %d  (mean %.1f)", tMin, tMax, tMean)
        lines[#lines + 1] = string.format("Composition:  %d - %d  (mean %.1f)", cMin, cMax, cMean)
        lines[#lines + 1] = string.format("Emotion:      %d - %d  (mean %.1f)", eMin, eMax, eMean)
        lines[#lines + 1] = string.format("Moment:       %d - %d  (mean %.1f)", mMin, mMax, mMean)

        -- Composite histogram
        local buckets = {}
        for b = 1, 10 do buckets[b] = 0 end
        for _, v in ipairs(allScores.composite) do
            local b = math.floor(v + 0.5)
            if b < 1 then b = 1 end
            if b > 10 then b = 10 end
            buckets[b] = buckets[b] + 1
        end

        local maxB = 0
        for b = 1, 10 do
            if buckets[b] > maxB then maxB = buckets[b] end
        end

        lines[#lines + 1] = ""
        lines[#lines + 1] = "Composite Score Distribution:"
        local barW = 16
        for b = 1, 10 do
            local bar = ""
            if maxB > 0 then
                local len = math.floor(buckets[b] / maxB * barW + 0.5)
                bar = string.rep("#", len)
            end
            lines[#lines + 1] = string.format(
                " %2d | %-" .. barW .. "s %d", b, bar, buckets[b])
        end
    end

    -- Cost summary
    local costSummary = Engine.formatCostSummary()
    lines[#lines + 1] = "\n-- Cost --"
    lines[#lines + 1] = costSummary
    log:log("Pass 1 cost: " .. costSummary)

    if log.enabled and log.filePath then
        lines[#lines + 1] = "\nLog saved to: " .. log.filePath
    end
    if log.initError then
        lines[#lines + 1] = "\nLogging failed: " .. log.initError
    end

    return successCount, #errorLog, skippedScored, table.concat(lines, "\n"), allSnapshots
end

-- == Module export vs standalone entry point ==================================
if _G._AI_SELECTS_MODULE_LOAD then
    return { runScoring = runScoring }
end

-- Standalone entry point (menu item): wrap in async task.
LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("AISelectsScorePhotos", function(context)
        local success, errors, skips, summary = runScoring(context)
        if summary then
            LrDialogs.message("AI Selects - Scoring Complete", summary, "info")
        end
    end)
end)
