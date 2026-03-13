--[[
  ScorePhotos.lua
  ─────────────────────────────────────────────────────────────────────────────
  Pass 1: Iterates over selected Lightroom Classic photos, renders each one,
  sends to Ollama or Claude API for scoring, and writes scores to custom
  metadata fields.

  Can be invoked directly (as a menu item) or via ScoreAndSelect.lua
  which calls the exported runScoring(context) function.

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

local Engine = dofile(_PLUGIN.path .. '/AIEngine.lua')
local Prefs  = dofile(_PLUGIN.path .. '/Prefs.lua')

-- ── Logger ────────────────────────────────────────────────────────────────
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

    self:log("═══════════════════════════════════════════════════════════")
    self:log("AI Selects - Scoring started at " .. LrDate.timeToUserFormat(self.startTime, "%Y-%m-%d %H:%M:%S"))
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
    self:log("Skip scored: " .. tostring(settings.skipScored))
    self:log("Calibration: " .. tostring(settings.enableCalibration))
    self:log("═══════════════════════════════════════════════════════════")
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

function Logger:logImage(filename, result, detail)
    if not self.enabled then return end
    if result == "success" then
        self:log("[OK]    " .. filename .. "  ->  " .. detail)
    elseif result == "skipped" then
        self:log("[SKIP]  " .. filename .. "  ->  " .. detail)
    else
        self:log("[FAIL]  " .. filename .. "  ->  " .. detail)
    end
end

function Logger:finish(successCount, errorCount, skippedCount)
    if not self.enabled then return end
    local elapsed = LrDate.currentTime() - self.startTime
    self:log("═══════════════════════════════════════════════════════════")
    self:log(string.format("Run complete - %d scored, %d errors, %d skipped (%.0fs elapsed)",
        successCount, errorCount, skippedCount, elapsed))
    self:log("═══════════════════════════════════════════════════════════")

    if self.fileHandle then
        self.fileHandle:close()
        self.fileHandle = nil
    end
end

-- ── Query and score a single photo ──────────────────────────────────────
local function scorePhoto(photo, settings, imageIndex, promptOverride)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000)) .. "_" .. tostring(imageIndex or 0)

    local img, err = Engine.prepareImage(photo, ts, settings.provider, settings.renderSize)
    if not img then return nil, nil, err end

    local prompt = promptOverride or Engine.SCORING_PROMPT

    local raw
    if settings.provider == "claude" then
        raw, err = Engine.queryClaude(img, prompt, settings.claudeModel,
            settings.claudeApiKey, settings.timeoutSecs)
    elseif settings.provider == "openai" then
        raw, err = Engine.queryOpenAI(img, prompt, settings.openaiModel,
            settings.openaiApiKey, settings.timeoutSecs)
    elseif settings.provider == "gemini" then
        raw, err = Engine.queryGemini(img, prompt, settings.geminiModel,
            settings.geminiApiKey, settings.timeoutSecs)
    else
        raw, err = Engine.queryOllama(img, prompt, settings.model,
            settings.ollamaUrl, settings.timeoutSecs)
    end

    if not raw then return nil, nil, err end

    local scores, parseErr = Engine.parseScoreResponse(raw)
    if not scores then
        return nil, raw, parseErr
    end

    return scores, raw, nil
end

-- ── Write scores to custom metadata ────────────────────────────────────
local function writeScores(catalog, photo, scores, phash, filename)
    local writeResult = catalog:withWriteAccessDo(
        "AI Selects - Score " .. filename,
        function()
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsTechnical',  tostring(scores.technical))
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsAesthetic',  tostring(scores.aesthetic))
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsContent',    scores.content)
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsCategory',   scores.dominated_by)
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsReject',     tostring(scores.reject))
            if scores.eye_quality then
                photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsEyeQuality', scores.eye_quality)
            end
            if scores.narrative_role then
                photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsNarrativeRole', scores.narrative_role)
            end
            if phash then
                photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsPhash',  phash)
            end
            photo:setPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate',
                LrDate.timeToUserFormat(LrDate.currentTime(), "%Y-%m-%d %H:%M:%S"))
        end,
        { timeout = 10 }
    )
    return writeResult
end

-- ── Calibration helpers ───────────────────────────────────────────────

-- Sample photos evenly distributed across the capture timeline.
-- Returns an array of indices into the photos array.
local function sampleCalibrationPhotos(photos, sampleCount)
    if #photos <= sampleCount then
        local indices = {}
        for i = 1, #photos do indices[i] = i end
        return indices
    end

    -- Build (index, captureTime) pairs and sort by capture time
    local timed = {}
    for i, photo in ipairs(photos) do
        local captureTime = photo:getRawMetadata('dateTimeOriginal')
        timed[#timed + 1] = { idx = i, time = captureTime or 0 }
    end
    table.sort(timed, function(a, b) return a.time < b.time end)

    -- Pick evenly spaced indices from the sorted timeline
    local indices = {}
    local step = #timed / sampleCount
    for s = 0, sampleCount - 1 do
        local pos = math.floor(s * step + step / 2) + 1
        pos = math.min(pos, #timed)
        indices[#indices + 1] = timed[pos].idx
    end

    return indices
end

-- Compute calibration statistics from an array of score tables.
-- Returns stats table for buildCalibratedPrompt() and calibration dialog,
-- or nil if insufficient data.
local function computeCalibrationStats(scoredResults)
    if #scoredResults < 2 then return nil end

    -- Use composite score (average of technical + aesthetic) for distribution
    local composites = {}
    for _, s in ipairs(scoredResults) do
        composites[#composites + 1] = {
            composite = (s.technical + s.aesthetic) / 2,
            content = s.content or "unknown",
        }
    end

    table.sort(composites, function(a, b) return a.composite < b.composite end)

    local sum, sumSq = 0, 0
    local minVal, maxVal = 10, 1
    -- Per-dimension tracking
    local techMin, techMax, techSum = 10, 1, 0
    local aestMin, aestMax, aestSum = 10, 1, 0

    for i, c in ipairs(composites) do
        local v = c.composite
        sum = sum + v
        sumSq = sumSq + v * v
        if v < minVal then minVal = v end
        if v > maxVal then maxVal = v end
    end

    for _, s in ipairs(scoredResults) do
        if s.technical < techMin then techMin = s.technical end
        if s.technical > techMax then techMax = s.technical end
        techSum = techSum + s.technical
        if s.aesthetic < aestMin then aestMin = s.aesthetic end
        if s.aesthetic > aestMax then aestMax = s.aesthetic end
        aestSum = aestSum + s.aesthetic
    end

    local n = #composites
    local mean = sum / n
    local variance = (sumSq / n) - (mean * mean)
    local stddev = math.sqrt(math.max(0, variance))

    return {
        -- Composite stats (used by buildCalibratedPrompt)
        min = math.floor(minVal + 0.5),
        max = math.floor(maxVal + 0.5),
        mean = mean,
        stddev = stddev,
        bestContent = composites[n].content,
        worstContent = composites[1].content,
        sampleCount = n,
        -- Per-dimension stats (used by calibration dialog)
        techMin = techMin, techMax = techMax, techMean = techSum / n,
        aestMin = aestMin, aestMax = aestMax, aestMean = aestSum / n,
    }
end

-- ── Shared setup: validate photos, API keys, filter file types ────────
-- Returns (SETTINGS, catalog, toProcess, skipped) or nil on error/cancel.
local function validateAndPrepare()
    local SETTINGS = Prefs.getPrefs()
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
            table.insert(toProcess, photo)
        else
            table.insert(skipped, LrPathUtils.leafName(path))
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
    pcall(function()
        LrTasks.execute("rm -f /tmp/ai_sel_req_* /tmp/ai_sel_resp_* /tmp/ai_sel_cfg_* 2>/dev/null")
    end)

    return SETTINGS, catalog, toProcess, skipped
end

-- ── Resolve provider display info ────────────────────────────────────
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
    return providerLabel, modelName
end

-- ── Calibration pass ─────────────────────────────────────────────────
-- Runs setup, validation, and calibration phase.
-- Returns a result table for runScoring(), or nil on error/cancel.
-- Result table: { calibrationStats, calibratedPrompt, calibratedSet,
--   toProcess, skipped, log, SETTINGS, catalog, providerLabel, modelName,
--   calSuccessCount, calSkippedScored, calErrorLog }
local function runCalibration(context)
    local SETTINGS, catalog, toProcess, skipped = validateAndPrepare()
    if not SETTINGS then return nil end

    local providerLabel, modelName = getProviderInfo(SETTINGS)

    -- Initialize logger
    local log = setmetatable({}, { __index = Logger })
    log:init(SETTINGS)
    log:log("Scoring prompt: " .. Engine.SCORING_PROMPT)

    local calibratedPrompt = nil
    local calibratedSet = {}
    local calibrationStats = nil
    local successCount = 0
    local skippedScored = 0
    local errorLog = {}

    if SETTINGS.enableCalibration and #toProcess >= 10 then
        local progress = LrProgressScope({
            title           = "AI Selects - Calibrating (" .. providerLabel .. " - " .. modelName .. ")",
            functionContext = context,
        })

        local sampleSize = math.max(10, math.min(50, math.floor(#toProcess * 0.05)))
        local sampleIndices = sampleCalibrationPhotos(toProcess, sampleSize)

        log:log(string.format("Calibration: sampling %d of %d photos", #sampleIndices, #toProcess))

        local calScores = {}

        for ci, photoIdx in ipairs(sampleIndices) do
            if progress:isCanceled() then
                log:log("Calibration canceled by user")
                progress:done()
                log:finish(successCount, #errorLog, skippedScored)
                return nil
            end

            local photo = toProcess[photoIdx]
            local path = photo:getRawMetadata('path')
            local filename = LrPathUtils.leafName(path)

            progress:setPortionComplete(ci - 1, #sampleIndices)
            progress:setCaption(string.format("Calibrating [%d/%d] %s",
                ci, #sampleIndices, filename))

            -- If skipScored is on, try to use existing scores for calibration
            local alreadyScored = false
            if SETTINGS.skipScored then
                local scoreDate = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate')
                if scoreDate and scoreDate ~= "" then
                    local existingTech = tonumber(
                        photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsTechnical'))
                    local existingAest = tonumber(
                        photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsAesthetic'))
                    local existingContent =
                        photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsContent')
                    if existingTech and existingAest then
                        calScores[#calScores + 1] = {
                            technical = existingTech,
                            aesthetic = existingAest,
                            content = existingContent or "unknown",
                        }
                        calibratedSet[photoIdx] = true
                        alreadyScored = true
                        skippedScored = skippedScored + 1
                        log:logImage(filename, "skipped",
                            "calibration sample - using existing scores")
                    end
                end
            end

            if not alreadyScored then
                local scores, rawResponse, err = scorePhoto(photo, SETTINGS, photoIdx)

                if rawResponse then
                    log:log(string.format("  Cal raw response: %s", rawResponse:sub(1, 500)))
                end

                if scores then
                    local phash, phashErr = Engine.computePhash(photo,
                        tostring(math.floor(LrDate.currentTime() * 1000))
                        .. "_cal_" .. tostring(ci))
                    if phashErr then
                        log:log("  Phash warning: " .. phashErr)
                    end

                    LrTasks.yield()
                    local writeOk, writeErr = LrTasks.pcall(function()
                        local writeResult = writeScores(
                            catalog, photo, scores, phash, filename)
                        if writeResult ~= "executed" then
                            error("Catalog write not executed (result: "
                                .. tostring(writeResult) .. ")")
                        end
                    end)
                    LrTasks.yield()

                    if writeOk then
                        calScores[#calScores + 1] = scores
                        calibratedSet[photoIdx] = true
                        successCount = successCount + 1
                        log:logImage(filename, "success",
                            string.format("Cal: Tech:%d Aest:%d %s",
                                scores.technical, scores.aesthetic, scores.content))
                    else
                        table.insert(errorLog,
                            "- " .. filename .. "\n  Cal write error: "
                            .. tostring(writeErr))
                        log:logImage(filename, "error",
                            "Cal write failed: " .. tostring(writeErr))
                    end
                else
                    table.insert(errorLog,
                        "- " .. filename .. "\n  Cal: " .. (err or "unknown error"))
                    log:logImage(filename, "error", "Cal: " .. (err or "unknown"))
                end
            end

            LrTasks.sleep(0.05)
        end

        progress:setPortionComplete(1, 1)
        progress:done()

        -- Compute stats and build calibrated prompt
        local calStats = computeCalibrationStats(calScores)
        if calStats then
            calibrationStats = calStats
            calibratedPrompt = Engine.buildCalibratedPrompt(calStats)
            log:log(string.format(
                "Calibration complete: min=%d max=%d mean=%.1f stddev=%.1f best='%s' worst='%s'",
                calStats.min, calStats.max, calStats.mean, calStats.stddev,
                calStats.bestContent, calStats.worstContent))
            log:log("Calibrated prompt: " .. calibratedPrompt:sub(1, 500))
        else
            log:log("Calibration: insufficient data, using standard prompt")
        end
    elseif SETTINGS.enableCalibration and #toProcess < 10 then
        log:log("Calibration: skipped (fewer than 10 photos)")
    end

    return {
        calibrationStats  = calibrationStats,
        calibratedPrompt  = calibratedPrompt,
        calibratedSet     = calibratedSet,
        toProcess         = toProcess,
        skipped           = skipped,
        log               = log,
        SETTINGS          = SETTINGS,
        catalog           = catalog,
        providerLabel     = providerLabel,
        modelName         = modelName,
        calSuccessCount   = successCount,
        calSkippedScored  = skippedScored,
        calErrorLog       = errorLog,
    }
end

-- ── Core scoring logic ─────────────────────────────────────────────────
-- Exported so ScoreAndSelect.lua can call it within its own async context.
-- When calResult is provided (from runCalibration), skips setup/validation/calibration.
-- When calResult is nil, runs the full flow (standalone menu item).
-- Returns (successCount, errorCount, skippedCount, summary) or nil on error/cancel.
local function runScoring(context, calResult)
    -- Standalone mode: run calibration pass first
    if not calResult then
        calResult = runCalibration(context)
        if not calResult then return nil end
    end

    local SETTINGS        = calResult.SETTINGS
    local catalog         = calResult.catalog
    local toProcess       = calResult.toProcess
    local skipped         = calResult.skipped
    local log             = calResult.log
    local providerLabel   = calResult.providerLabel
    local modelName       = calResult.modelName
    local calibratedPrompt = calResult.calibratedPrompt
    local calibratedSet   = calResult.calibratedSet
    local calibrationStats = calResult.calibrationStats
    local successCount    = calResult.calSuccessCount
    local skippedScored   = calResult.calSkippedScored
    local errorLog        = calResult.calErrorLog
    local startTime       = LrDate.currentTime()

    -- ── Main scoring loop ──────────────────────────────────────────────

    local progress = LrProgressScope({
        title           = "AI Selects (" .. providerLabel .. " - " .. modelName .. ")",
        functionContext = context,
    })

    for i, photo in ipairs(toProcess) do
        if progress:isCanceled() then
            log:log("Run canceled by user at image " .. i)
            break
        end

        -- Skip photos already scored during calibration
        if calibratedSet[i] then
            -- already counted in successCount during calibration
        else

        local path     = photo:getRawMetadata('path')
        local filename = LrPathUtils.leafName(path)

        progress:setPortionComplete(i - 1, #toProcess)

        -- Skip already-scored photos
        local shouldSkip = false
        if SETTINGS.skipScored then
            local scoreDate = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate')
            if scoreDate and scoreDate ~= "" then
                skippedScored = skippedScored + 1
                shouldSkip = true
                log:logImage(filename, "skipped", "already scored on " .. scoreDate)
            end
        end

        if not shouldSkip then

        -- ETA calculation
        local eta = ""
        if successCount > 0 then
            local elapsed = LrDate.currentTime() - startTime
            local avgTime = elapsed / (successCount + #errorLog)
            local remaining = avgTime * (#toProcess - i)
            eta = string.format(" - ~%d min remaining", math.ceil(remaining / 60))
        end

        progress:setCaption(string.format("[%d/%d] %s%s", i, #toProcess, filename, eta))

        -- Query AI model (use calibrated prompt if available)
        local queryStart = LrDate.currentTime()
        local scores, rawResponse, err = scorePhoto(photo, SETTINGS, i, calibratedPrompt)
        local queryElapsed = LrDate.currentTime() - queryStart

        if rawResponse then
            log:log(string.format("  Raw response: %s", rawResponse:sub(1, 500)))
        end
        log:log(string.format("  Query time: %.1fs", queryElapsed))

        if scores then
            -- Compute perceptual hash for duplicate detection
            local phash, phashErr = Engine.computePhash(photo,
                tostring(math.floor(LrDate.currentTime() * 1000)) .. "_" .. tostring(i))
            if phashErr then
                log:log("  Phash warning: " .. phashErr)
            end

            -- Write scores + hash to catalog
            LrTasks.yield()
            local writeOk, writeErr = LrTasks.pcall(function()
                local writeResult = writeScores(catalog, photo, scores, phash, filename)
                if writeResult ~= "executed" then
                    error("Catalog write not executed (result: " .. tostring(writeResult) .. ")")
                end
            end)
            LrTasks.yield()

            if writeOk then
                successCount = successCount + 1
                local hashStr = phash and (" Hash:" .. phash) or ""
                local eyeStr = (scores.eye_quality and scores.eye_quality ~= "na")
                    and (" Eye:" .. scores.eye_quality) or ""
                local detail = string.format("Tech:%d Aest:%d Cat:%s Content:%s%s%s%s",
                    scores.technical, scores.aesthetic,
                    scores.dominated_by, scores.content,
                    eyeStr,
                    scores.reject and " [REJECT]" or "",
                    hashStr)
                log:logImage(filename, "success", detail)
            else
                table.insert(errorLog, "- " .. filename .. "\n  Write error: " .. tostring(writeErr))
                log:logImage(filename, "error", "Write failed: " .. tostring(writeErr))
            end
        else
            table.insert(errorLog, "- " .. filename .. "\n  " .. (err or "unknown error"))
            log:logImage(filename, "error", err or "unknown error")
        end

        end -- if not shouldSkip

        end -- if not calibratedSet[i]

        LrTasks.sleep(0.05)
    end

    progress:setPortionComplete(1, 1)
    progress:done()

    -- Finish log
    log:finish(successCount, #errorLog, skippedScored)

    -- Build completion message
    local elapsed = LrDate.currentTime() - startTime
    local lines = { string.format("%d photo(s) scored via %s (%.0fs elapsed)",
        successCount, providerLabel, elapsed) }
    if calibrationStats then
        lines[#lines + 1] = string.format(
            "Calibration: %d samples, scores %d-%d (mean %.1f, stddev %.1f)",
            calibrationStats.sampleCount,
            calibrationStats.min, calibrationStats.max,
            calibrationStats.mean, calibrationStats.stddev)
    end
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
    if log.enabled and log.filePath then
        lines[#lines + 1] = "\nLog saved to: " .. log.filePath
    end
    if log.initError then
        lines[#lines + 1] = "\nLogging failed: " .. log.initError
    end

    return successCount, #errorLog, skippedScored, table.concat(lines, "\n")
end

-- ── Module export vs standalone entry point ────────────────────────────
-- When loaded via dofile from ScoreAndSelect.lua, the caller sets this
-- global flag so we skip the standalone async task (otherwise two scoring
-- runs would start simultaneously).
if _G._AI_SELECTS_MODULE_LOAD then
    return { runScoring = runScoring, runCalibration = runCalibration }
end

-- Standalone entry point (menu item): wrap in async task + error handler.
LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("AISelectsScorePhotos", function(context)
        local ok, err = LrTasks.pcall(function()
            local success, errors, skips, summary = runScoring(context)
            if summary then
                LrDialogs.message("AI Selects - Scoring Complete", summary, "info")
            end
        end)
        if not ok then
            LrDialogs.message("AI Selects - Error",
                "An unexpected error occurred during scoring:\n\n" .. tostring(err), "critical")
        end
    end)
end)
