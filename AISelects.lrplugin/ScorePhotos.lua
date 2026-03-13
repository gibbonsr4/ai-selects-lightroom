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
    else
        self:log("Model: " .. settings.claudeModel)
    end
    self:log("Render size: " .. tostring(settings.renderSize) .. "px")
    self:log("Skip scored: " .. tostring(settings.skipScored))
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
local function scorePhoto(photo, settings, imageIndex)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000)) .. "_" .. tostring(imageIndex or 0)

    local img, err = Engine.prepareImage(photo, ts, settings.provider, settings.renderSize)
    if not img then return nil, nil, err end

    local prompt = Engine.SCORING_PROMPT

    local raw
    if settings.provider == "claude" then
        raw, err = Engine.queryClaude(img, prompt, settings.claudeModel,
            settings.claudeApiKey, settings.timeoutSecs)
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

-- ── Core scoring logic ─────────────────────────────────────────────────
-- Exported so ScoreAndSelect.lua can call it within its own async context.
-- Returns (successCount, errorCount, skippedCount) or shows error dialog and returns nil.
local function runScoring(context)
    local SETTINGS = Prefs.getPrefs()
    local catalog      = LrApplication.activeCatalog()
    local targetPhotos = catalog:getTargetPhotos()

    if #targetPhotos == 0 then
        LrDialogs.message("AI Selects",
            "No photos selected.\n\nSelect one or more photos in the Library grid and try again.", "info")
        return nil
    end

    -- Validate Claude API key
    if SETTINGS.provider == "claude" and (SETTINGS.claudeApiKey == nil or SETTINGS.claudeApiKey == "") then
        LrDialogs.message("AI Selects",
            "Claude API selected but no API key configured.\n\nOpen Settings and enter your Anthropic API key.", "warning")
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

    if #toProcess > 50 then
        local confirm = LrDialogs.confirm(
            "Score " .. #toProcess .. " Photos?",
            "This may take several minutes depending on your hardware and AI provider.\n\nProceed?",
            "Proceed", "Cancel")
        if confirm ~= "ok" then return nil end
    end

    -- Clean up orphaned temp files from interrupted runs
    pcall(function()
        LrTasks.execute("rm -f /tmp/ai_sel_req_* /tmp/ai_sel_resp_* /tmp/ai_sel_cfg_* 2>/dev/null")
    end)

    -- Initialize logger
    local log = setmetatable({}, { __index = Logger })
    log:init(SETTINGS)
    log:log("Scoring prompt: " .. Engine.SCORING_PROMPT)

    local modelName = SETTINGS.provider == "claude" and SETTINGS.claudeModel or SETTINGS.model
    local providerLabel = SETTINGS.provider == "claude" and "Claude API" or "Ollama"
    local progress = LrProgressScope({
        title           = "AI Selects (" .. providerLabel .. " - " .. modelName .. ")",
        functionContext = context,
    })

    local successCount  = 0
    local skippedScored = 0
    local errorLog      = {}
    local startTime     = LrDate.currentTime()

    for i, photo in ipairs(toProcess) do
        if progress:isCanceled() then
            log:log("Run canceled by user at image " .. i)
            break
        end

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

        -- Query AI model
        local queryStart = LrDate.currentTime()
        local scores, rawResponse, err = scorePhoto(photo, SETTINGS, i)
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
    return { runScoring = runScoring }
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
