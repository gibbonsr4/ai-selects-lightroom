--[[
  AIEngine.lua
  ─────────────────────────────────────────────────────────────────────────────
  Shared AI inference engine — image rendering, API calls, score parsing.
  Used by ScorePhotos.lua and SelectPhotos.lua.
  Pure functions, no UI, no side effects beyond temp files.

  Forked from AI Keywords plugin (AIEngine.lua).
--]]

local LrApplication     = import 'LrApplication'
local LrDate            = import 'LrDate'
local LrExportSession   = import 'LrExportSession'
local LrFileUtils       = import 'LrFileUtils'
local LrPathUtils       = import 'LrPathUtils'
local LrTasks           = import 'LrTasks'

local json = dofile(_PLUGIN.path .. '/dkjson.lua')

local M = {}

-- ── Constants ─────────────────────────────────────────────────────────────
M.TEMP_DIR = "/tmp"

-- Claude's base64 image limit is 5MB. Base64 is ~4/3 of raw, so raw limit ~3.75MB.
M.CLAUDE_MAX_RAW_BYTES = 3750000

-- Minimum image dimension — images smaller than this won't produce useful scores
M.MIN_IMAGE_DIMENSION = 200

-- SUPPORTED_EXTS is checked before LrExportSession to give clear error messages
-- for unsupported formats (e.g. PSD, AI) instead of opaque render failures.
M.SUPPORTED_EXTS = {
    jpg = true, jpeg = true, png = true,
    tif = true, tiff = true, webp = true,
    heic = true, heif = true,
    -- RAW formats — LrExportSession handles these natively
    cr2 = true, cr3 = true, nef = true, arw = true,
    raf = true, orf = true, rw2 = true, dng = true,
    pef = true, srw = true,
}

-- ── Recommended vision models for Ollama ──────────────────────────────────
-- This hardcoded list is the offline fallback.  On Settings open the plugin
-- fetches models.json from the GitHub repo for an up-to-date list.
M.VISION_MODELS = {
    { value = "gemma3:4b",            label = "Gemma 3 4B",             info = "~3GB RAM  |  Popular, versatile vision model" },
    { value = "qwen2.5vl:3b",        label = "Qwen2.5-VL 3B",          info = "~2GB RAM  |  Fastest, good quality  |  Requires Ollama 0.7+" },
    { value = "minicpm-v",            label = "MiniCPM-V 8B",           info = "~5GB RAM  |  Fast, strong detail recognition" },
    { value = "qwen2.5vl:7b",        label = "Qwen2.5-VL 7B",          info = "~5GB RAM  |  Best local quality, accurate IDs  |  Requires Ollama 0.7+" },
    { value = "qwen3-vl:8b",         label = "Qwen3-VL 8B",            info = "~5GB RAM  |  Next-gen Qwen vision  |  Requires Ollama 0.7+" },
    { value = "gemma3:12b",          label = "Gemma 3 12B",            info = "~8GB RAM  |  High quality, strong all-rounder" },
    { value = "llama3.2-vision:11b",  label = "Llama 3.2 Vision 11B",   info = "~8GB RAM  |  Solid all-rounder" },
    { value = "moondream",            label = "Moondream 2",            info = "~1GB RAM  |  Tiny, fast, basic scoring only" },
}

-- ── Remote model list URL ───────────────────────────────────────────────
M.MODELS_JSON_URL =
    "https://raw.githubusercontent.com/gibbonsr4/ai-editor-lightroom/main/models.json"

-- ── Scoring prompt ──────────────────────────────────────────────────────
M.SCORING_PROMPT = [[Rate this photo for a curated photo selection.
Return ONLY a JSON object with these fields:
- technical (1-10): sharpness, exposure, noise, white balance. Scale: 1-2 = technically broken (severe blur, black frame, accidental shot), 3-4 = poor (noticeable problems but identifiable subject), 5-6 = acceptable (average snapshot, nothing remarkable), 7-8 = good (solid technique, well exposed, intentional), 9-10 = exceptional (tack sharp, perfect exposure, professional quality).
- aesthetic (1-10): composition, lighting, mood, visual impact. Scale: 1-2 = no compositional intent, 3-4 = basic snapshot framing, 5-6 = competent but unremarkable, 7-8 = strong composition with good light and mood, 9-10 = striking image with excellent visual impact.
- content: 3-5 word description of the main subject/scene
- dominated_by: primary visual category (one of: 'landscape', 'portrait', 'wildlife', 'architecture', 'food', 'street', 'macro', 'event', 'nature', 'other')
- narrative_role: best editorial role for this image (one of: 'scene_setter', 'character_moment', 'action', 'detail', 'transition', 'closing', 'establishing', 'emotional_peak')
- eye_quality: for the most prominent person visible (one of: 'good' = open/sharp/engaged, 'fair' = open but soft or looking away, 'closed' = eyes closed or squinting, 'na' = no people or faces visible). For action/movement shots, reward the peak moment (full extension, contact, height of jump) over wind-up or follow-through.
- reject: true if obviously bad (severe blur, badly exposed, accidental/unintentional shot). Do not reject images that are merely average.
Do not explain your reasoning. Return only valid JSON.]]

-- ── Base64 encoder ────────────────────────────────────────────────────────
-- Pre-built lookup table avoids repeated string.sub() calls per character.
local B64_CHAR = {}
do
    local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    for i = 0, 63 do B64_CHAR[i] = B64:sub(i + 1, i + 1) end
end

function M.base64Encode(data)
    local result = {}
    local len = #data
    for i = 1, len - 2, 3 do
        local b1, b2, b3 = data:byte(i, i + 2)
        local n = b1 * 65536 + b2 * 256 + b3
        result[#result + 1] = B64_CHAR[math.floor(n / 262144)]
            .. B64_CHAR[math.floor(n / 4096) % 64]
            .. B64_CHAR[math.floor(n / 64) % 64]
            .. B64_CHAR[n % 64]
    end
    local r = len % 3
    if r == 1 then
        local n = data:byte(len) * 65536
        result[#result + 1] = B64_CHAR[math.floor(n / 262144)]
            .. B64_CHAR[math.floor(n / 4096) % 64] .. '=='
    elseif r == 2 then
        local b1, b2 = data:byte(len - 1, len)
        local n = b1 * 65536 + b2 * 256
        result[#result + 1] = B64_CHAR[math.floor(n / 262144)]
            .. B64_CHAR[math.floor(n / 4096) % 64]
            .. B64_CHAR[math.floor(n / 64) % 64] .. '='
    end
    return table.concat(result)
end

-- ── File & string helpers ─────────────────────────────────────────────────
function M.readBinaryFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*all'); f:close(); return data
end

function M.fileSize(path)
    local attrs = LrFileUtils.fileAttributes(path)
    return (attrs and attrs.fileSize) or 0
end

function M.getExt(path)
    return (LrPathUtils.extension(path) or ''):lower()
end

function M.trim(s)
    return s:match("^%s*(.-)%s*$") or ''
end

function M.safeDelete(path)
    pcall(function() LrFileUtils.delete(path) end)
end

-- POSIX-safe shell escaping: wrap in single quotes, escape internal single quotes.
-- This prevents injection via $(...), backticks, double-quote tricks, etc.
function M.shellEscape(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ── Ollama status helpers ─────────────────────────────────────────────────
function M.isOllamaInstalled()
    local appExists = LrFileUtils.exists("/Applications/Ollama.app")
    if appExists then return true end
    local exitCode = LrTasks.execute("which ollama >/dev/null 2>&1")
    return exitCode == 0
end

function M.getInstalledModels(ollamaUrl)
    local installed = {}
    local tmpCfg = M.TEMP_DIR .. "/ai_sel_tags_cfg.txt"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_tags.json"

    local cfh = io.open(tmpCfg, "w")
    if not cfh then return installed, false end
    cfh:write("-s\n")
    cfh:write(string.format('url = "%s/api/tags"\n', ollamaUrl))
    cfh:write("max-time = 5\n")
    cfh:close()

    local cmd = string.format("curl -K %s -o %s", M.shellEscape(tmpCfg), M.shellEscape(tmpOut))
    local exitCode = LrTasks.execute(cmd)

    if exitCode == 0 then
        local rf = io.open(tmpOut, "r")
        if rf then
            local response = rf:read("*all")
            rf:close()
            pcall(function() LrFileUtils.delete(tmpCfg) end)
            pcall(function() LrFileUtils.delete(tmpOut) end)
            if response and response ~= "" then
                local success, data = pcall(function() return json.decode(response) end)
                if success and data and data.models then
                    for _, m in ipairs(data.models) do
                        installed[m.name] = true
                        local base = m.name:match("^([^:]+)")
                        if base then installed[base] = true end
                        local withoutLatest = m.name:gsub(":latest$", "")
                        installed[withoutLatest] = true
                    end
                end
                return installed, true
            end
        end
    end

    pcall(function() LrFileUtils.delete(tmpCfg) end)
    pcall(function() LrFileUtils.delete(tmpOut) end)
    return installed, false
end

function M.isModelInstalled(installed, modelValue)
    if installed[modelValue] then return true end
    local base, tag = modelValue:match("^([^:]+):?(.*)")
    if base and (tag == nil or tag == "") and installed[base] then return true end
    return false
end

function M.fetchRemoteModels()
    local tmpCfg = M.TEMP_DIR .. "/ai_sel_models_cfg.txt"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_models.json"

    local cfh = io.open(tmpCfg, "w")
    if not cfh then return nil end
    cfh:write("-s\n")
    cfh:write(string.format('url = "%s"\n', M.MODELS_JSON_URL))
    cfh:write("max-time = 5\n")
    cfh:close()

    local cmd = string.format("curl -K %s -o %s", M.shellEscape(tmpCfg), M.shellEscape(tmpOut))
    local exitCode = LrTasks.execute(cmd)

    if exitCode == 0 then
        local rf = io.open(tmpOut, "r")
        if rf then
            local raw = rf:read("*all")
            rf:close()
            pcall(function() LrFileUtils.delete(tmpCfg) end)
            pcall(function() LrFileUtils.delete(tmpOut) end)
            if raw and raw ~= "" then
                local ok, data = pcall(function() return json.decode(raw) end)
                if ok and type(data) == "table" and data.models and #data.models > 0 then
                    return data.models
                end
            end
        end
    end

    pcall(function() LrFileUtils.delete(tmpCfg) end)
    pcall(function() LrFileUtils.delete(tmpOut) end)
    return nil
end

-- ── Image rendering via LrExportSession ──────────────────────────────────
-- Uses Lightroom's own render pipeline. Handles every format LR can open
-- (RAW, HEIC, PSD, TIFF, etc.) and respects Develop adjustments.
-- Always outputs sRGB JPEG with minimal metadata, no sharpening/watermark.
-- Returns (jpegPath, fileSize) or (nil, errorMsg).
function M.renderImage(photo, ts, maxDimension)
    local dim = maxDimension or 512

    local exportSettings = {
        LR_export_destinationType       = 'specificFolder',
        LR_export_destinationPathPrefix = M.TEMP_DIR,
        LR_export_useSubfolder          = false,
        LR_format                       = 'JPEG',
        LR_jpeg_quality                 = 0.70,
        LR_export_colorSpace            = 'sRGB',
        LR_size_doConstrain             = true,
        LR_size_doNotEnlarge            = true,
        LR_size_maxHeight               = dim,
        LR_size_maxWidth                = dim,
        LR_size_resizeType              = 'longEdge',
        LR_reimportExportedPhoto        = false,
        LR_minimizeEmbeddedMetadata     = true,
        LR_outputSharpeningOn           = false,
        LR_useWatermark                 = false,
        LR_metadata_keywordOptions      = 'flat',
        LR_removeFaceMetadata           = true,
        LR_removeLocationMetadata       = true,
    }

    local session = LrExportSession({
        photosToExport = { photo },
        exportSettings = exportSettings,
    })

    for _, rendition in session:renditions() do
        local success, pathOrMsg = rendition:waitForRender()
        if success then
            local size = M.fileSize(pathOrMsg)
            if size > 0 then
                return pathOrMsg, size
            end
            M.safeDelete(pathOrMsg)
            return nil, "Render produced empty file"
        else
            return nil, "LR render failed: " .. tostring(pathOrMsg)
        end
    end

    return nil, "No renditions produced"
end

-- ── Prepare image for API ────────────────────────────────────────────────
-- Renders via LrExportSession, reads, base64-encodes.
-- Optional renderSize overrides provider defaults (used for 512px scoring).
-- For Claude, retries at smaller dimensions if file too large.
function M.prepareImage(photo, ts, provider, renderSize)
    -- Check minimum dimensions
    local dims = photo:getRawMetadata('croppedDimensions')
    if dims then
        local minEdge = math.min(dims.width, dims.height)
        if minEdge < M.MIN_IMAGE_DIMENSION then
            return nil, string.format("Image too small (%dx%d). Minimum edge: %dpx.",
                dims.width, dims.height, M.MIN_IMAGE_DIMENSION)
        end
    end

    -- Render dimension: use explicit renderSize if provided, else provider defaults
    local renderDim
    if renderSize then
        renderDim = renderSize
    elseif provider == "claude" then
        renderDim = 1568
    else
        renderDim = 1024
    end

    local renderedPath, renderedSize = M.renderImage(photo, ts, renderDim)

    -- For Claude without explicit renderSize: retry at smaller sizes if too large
    if provider == "claude" and not renderSize then
        if renderedPath and renderedSize > M.CLAUDE_MAX_RAW_BYTES then
            M.safeDelete(renderedPath)
            renderedPath, renderedSize = M.renderImage(photo, ts .. "_sm", 1024)
        end
        if renderedPath and renderedSize > M.CLAUDE_MAX_RAW_BYTES then
            M.safeDelete(renderedPath)
            renderedPath, renderedSize = M.renderImage(photo, ts .. "_xs", 768)
        end
    end

    if not renderedPath then
        return nil, renderedSize  -- renderedSize is the error message when path is nil
    end

    local imageData = M.readBinaryFile(renderedPath)
    M.safeDelete(renderedPath)

    if not imageData then
        return nil, "Cannot read rendered file"
    end

    -- Final size check for Claude
    if provider == "claude" and #imageData > M.CLAUDE_MAX_RAW_BYTES then
        return nil, string.format(
            "Image too large for Claude API (%.1f MB). Try exporting a smaller JPEG.",
            #imageData / 1048576
        )
    end

    return {
        base64   = M.base64Encode(imageData),
        fileSize = #imageData,
    }, nil
end

-- ── Score response parsing ──────────────────────────────────────────────
-- Robust JSON parser with three fallback levels for model responses.
-- Returns (scoresTable, nil) or (nil, errorMsg).
function M.normalizeScores(data)
    -- Validate eye_quality against allowed values
    local eyeVal = tostring(data.eye_quality or "na"):lower()
    local validEye = { good = true, fair = true, closed = true, na = true }
    if not validEye[eyeVal] then eyeVal = "na" end

    -- Validate dominated_by against closed category list
    local catVal = tostring(data.dominated_by or "other"):lower()
    local validCat = {
        landscape = true, portrait = true, wildlife = true,
        architecture = true, food = true, street = true,
        macro = true, event = true, nature = true, other = true,
    }
    if not validCat[catVal] then catVal = "other" end

    -- Validate narrative_role against allowed values
    local roleVal = tostring(data.narrative_role or "detail"):lower()
    local validRole = {
        scene_setter = true, character_moment = true, action = true,
        detail = true, transition = true, closing = true,
        establishing = true, emotional_peak = true,
    }
    if not validRole[roleVal] then roleVal = "detail" end

    return {
        technical      = math.max(1, math.min(10, tonumber(data.technical) or 5)),
        aesthetic      = math.max(1, math.min(10, tonumber(data.aesthetic) or 5)),
        content        = tostring(data.content or "unknown"),
        dominated_by   = catVal,
        narrative_role = roleVal,
        eye_quality    = eyeVal,
        reject         = (data.reject == true or data.reject == "true"),
    }
end

function M.parseScoreResponse(raw)
    if not raw or raw == "" then
        return nil, "Empty response from model"
    end

    -- Level 1: Direct JSON parse
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == "table" and data.technical then
        return M.normalizeScores(data), nil
    end

    -- Level 2: Extract JSON from markdown code block
    local jsonBlock = raw:match("```json%s*(.-)%s*```") or raw:match("```%s*(.-)%s*```")
    if jsonBlock then
        ok, data = pcall(json.decode, jsonBlock)
        if ok and type(data) == "table" and data.technical then
            return M.normalizeScores(data), nil
        end
    end

    -- Level 2b: Find JSON object in surrounding text
    local jsonStr = raw:match("%{.-%}")
    if jsonStr then
        ok, data = pcall(json.decode, jsonStr)
        if ok and type(data) == "table" and data.technical then
            return M.normalizeScores(data), nil
        end
    end

    -- Level 3: Regex field extraction as last resort
    local scores = {}
    scores.technical      = tonumber(raw:match('"technical"%s*:%s*(%d+)'))
    scores.aesthetic      = tonumber(raw:match('"aesthetic"%s*:%s*(%d+)'))
    scores.content        = raw:match('"content"%s*:%s*"([^"]*)"')
    scores.dominated_by   = raw:match('"dominated_by"%s*:%s*"([^"]*)"')
    scores.narrative_role = raw:match('"narrative_role"%s*:%s*"([^"]*)"')
    scores.eye_quality    = raw:match('"eye_quality"%s*:%s*"([^"]*)"')
    local rejectStr       = raw:match('"reject"%s*:%s*(%w+)')
    scores.reject         = (rejectStr == "true")

    if scores.technical then
        return M.normalizeScores(scores), nil
    end

    return nil, "Could not parse score response: " .. raw:sub(1, 200)
end

-- ── curl helper ──────────────────────────────────────────────────────────
-- Writes a curl config file with headers/URL/method, then invokes curl with
-- only controlled temp file paths on the command line. This prevents shell
-- injection and keeps sensitive values (API keys) out of the process list.
function M.writeCurlConfig(cfgPath, url, headers, timeoutSecs)
    local fh = io.open(cfgPath, "w")
    if not fh then return false end
    fh:write("-s\n")
    fh:write("-X POST\n")
    fh:write(string.format('url = "%s"\n', url))
    for _, h in ipairs(headers) do
        fh:write(string.format('header = "%s"\n', h))
    end
    fh:write(string.format("max-time = %d\n", timeoutSecs))
    fh:close()
    return true
end

function M.curlPost(cfgPath, tmpIn, tmpOut, imgSize, timeoutSecs)
    local curlCmd = string.format(
        "curl -K %s -d @%s -o %s",
        M.shellEscape(cfgPath), M.shellEscape(tmpIn), M.shellEscape(tmpOut)
    )
    local rawExit = LrTasks.execute(curlCmd)

    local result = nil
    local rf = io.open(tmpOut, "r")
    if rf then result = rf:read("*all"); rf:close() end

    M.safeDelete(cfgPath)
    M.safeDelete(tmpIn)
    M.safeDelete(tmpOut)

    if rawExit ~= 0 or not result or result == "" then
        local curlCode = math.floor(rawExit / 256)
        local signal   = rawExit % 128

        local detail
        if signal > 0 and curlCode == 0 then
            detail = string.format(
                "curl killed by signal %d. Image: %.1f MB. Timeout: %ds.",
                signal, imgSize / 1048576, timeoutSecs
            )
        else
            detail = string.format(
                "curl exit %d. Image: %.1f MB. Timeout: %ds.",
                curlCode, imgSize / 1048576, timeoutSecs
            )
            if curlCode == 28 then
                detail = detail .. " Timeout — increase timeout or use a faster model."
            elseif curlCode == 7 then
                detail = detail .. " Could not connect."
            end
        end
        return nil, detail
    end

    return result, nil
end

-- ── Ollama provider ──────────────────────────────────────────────────────
function M.queryOllama(img, prompt, modelName, ollamaUrl, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
    local encodeOk, body = pcall(json.encode, {
        model    = modelName,
        stream   = false,
        messages = {{
            role    = "user",
            content = prompt,
            images  = { img.base64 },
        }}
    })
    if not encodeOk then return nil, "JSON encode failed: " .. tostring(body) end

    local tmpCfg = M.TEMP_DIR .. "/ai_sel_cfg_" .. ts .. ".txt"
    local tmpIn  = M.TEMP_DIR .. "/ai_sel_req_" .. ts .. ".json"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_resp_" .. ts .. ".json"

    if not M.writeCurlConfig(tmpCfg, ollamaUrl .. "/api/chat",
            { "Content-Type: application/json" }, timeoutSecs) then
        return nil, "Could not write curl config file"
    end

    local fh = io.open(tmpIn, "w")
    if not fh then return nil, "Could not write temp file: " .. tmpIn end
    fh:write(body); fh:close()

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, img.fileSize, timeoutSecs)
    if not result then return nil, err end

    local ok, decoded = pcall(function() return json.decode(result) end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse Ollama response: " .. tostring(result):sub(1, 200)
    end
    if not (decoded.message and decoded.message.content) then
        return nil, "Unexpected Ollama response: " .. tostring(result):sub(1, 200)
    end

    return decoded.message.content, nil
end

-- ── Claude API provider ──────────────────────────────────────────────────
function M.queryClaude(img, prompt, claudeModel, apiKey, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
    local encodeOk, body = pcall(json.encode, {
        model      = claudeModel,
        max_tokens = 1024,
        messages   = {{
            role    = "user",
            content = {
                {
                    type   = "image",
                    source = {
                        type       = "base64",
                        media_type = "image/jpeg",
                        data       = img.base64,
                    },
                },
                {
                    type = "text",
                    text = prompt,
                },
            },
        }}
    })
    if not encodeOk then return nil, "JSON encode failed: " .. tostring(body) end

    local cleanKey = apiKey:gsub("%s+", "")

    local tmpCfg = M.TEMP_DIR .. "/ai_sel_cfg_" .. ts .. ".txt"
    local tmpIn  = M.TEMP_DIR .. "/ai_sel_req_" .. ts .. ".json"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_resp_" .. ts .. ".json"

    if not M.writeCurlConfig(tmpCfg, "https://api.anthropic.com/v1/messages", {
        "x-api-key: " .. cleanKey,
        "anthropic-version: 2023-06-01",
        "content-type: application/json",
    }, timeoutSecs) then
        return nil, "Could not write curl config file"
    end

    local fh = io.open(tmpIn, "w")
    if not fh then return nil, "Could not write temp file: " .. tmpIn end
    fh:write(body); fh:close()

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, img.fileSize, timeoutSecs)
    if not result then return nil, err end

    local ok, decoded = pcall(function() return json.decode(result) end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse Claude response: " .. tostring(result):sub(1, 200)
    end

    if decoded.error then
        return nil, "Claude API error: " .. (decoded.error.message or "Unknown")
    end

    if decoded.content and type(decoded.content) == "table" then
        for _, block in ipairs(decoded.content) do
            if block.type == "text" and block.text then
                return block.text, nil
            end
        end
    end

    return nil, "Unexpected Claude response: " .. tostring(result):sub(1, 200)
end

-- ── Perceptual hashing (dHash) via sips ─────────────────────────────────
-- Computes a 64-bit difference hash for visual duplicate detection.
-- Uses macOS built-in `sips` to resize to 9x8 BMP, then parses the BMP
-- pixel data in pure Lua. No external dependencies.
--
-- dHash: for each row of 9 pixels, compare adjacent pairs (left > right).
-- 8 rows x 8 comparisons = 64 bits, stored as 16-char hex string.
-- Similar images produce similar hashes; Hamming distance < 10 = likely duplicate.

-- Parse a 24-bit BMP file and return a 2D array of grayscale values.
-- BMP stores rows bottom-to-top, BGR byte order.
local function parseBmpGrayscale(path)
    local data = M.readBinaryFile(path)
    if not data or #data < 54 then return nil end

    -- BMP file header: pixel data offset at bytes 10-13 (little-endian)
    local function u32(offset)
        local b1, b2, b3, b4 = data:byte(offset, offset + 3)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    local function u16(offset)
        local b1, b2 = data:byte(offset, offset + 1)
        return b1 + b2 * 256
    end

    local pixelOffset = u32(11)     -- offset to pixel data
    local width       = u32(19)     -- image width
    local height      = u32(23)     -- image height (positive = bottom-up)
    local bpp         = u16(29)     -- bits per pixel

    if bpp ~= 24 then return nil end  -- only handle 24-bit BGR

    -- BMP rows are padded to 4-byte boundaries
    local rowBytes = math.ceil(width * 3 / 4) * 4

    local rows = {}
    for y = 0, height - 1 do
        local row = {}
        -- BMP is bottom-up, so row 0 in file = last row in image
        local rowStart = pixelOffset + (height - 1 - y) * rowBytes
        for x = 0, width - 1 do
            local pixStart = rowStart + x * 3 + 1  -- +1 for Lua 1-indexing
            if pixStart + 2 > #data then return nil end  -- BMP data truncated
            local b, g, r = data:byte(pixStart, pixStart + 2)
            -- Luminance formula (ITU-R BT.601)
            row[x + 1] = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
        end
        rows[y + 1] = row
    end

    return rows, width, height
end

-- Compute dHash from a grayscale pixel grid.
-- Grid must be at least 9 wide and 8 tall.
-- Returns a 16-character hex string (64 bits).
local function computeDhash(rows)
    local bits = {}
    for y = 1, 8 do
        local row = rows[y]
        if not row then return nil end
        for x = 1, 8 do
            -- 1 if current pixel is brighter than the next, 0 otherwise
            bits[#bits + 1] = (row[x] > row[x + 1]) and 1 or 0
        end
    end

    -- Convert 64 bits to 16-char hex string (4 bits per hex digit)
    local hex = {}
    for i = 1, 64, 4 do
        local nibble = bits[i] * 8 + bits[i+1] * 4 + bits[i+2] * 2 + bits[i+3]
        hex[#hex + 1] = string.format("%x", nibble)
    end
    return table.concat(hex)
end

-- Compute Hamming distance between two hex hash strings.
-- Returns number of differing bits (0 = identical, <10 = very similar).
function M.hashDistance(hash1, hash2)
    if not hash1 or not hash2 then return 64 end  -- max distance if missing
    if #hash1 ~= #hash2 then return 64 end

    local distance = 0
    for i = 1, #hash1 do
        local a = tonumber(hash1:sub(i, i), 16) or 0
        local b = tonumber(hash2:sub(i, i), 16) or 0
        -- XOR and popcount for one hex digit (4 bits)
        for bit = 0, 3 do
            local mask = 2 ^ bit
            local aBit = math.floor(a / mask) % 2
            local bBit = math.floor(b / mask) % 2
            if aBit ~= bBit then distance = distance + 1 end
        end
    end
    return distance
end

-- Compute perceptual hash for a Lightroom photo.
-- Renders a tiny version via LrExportSession, converts to BMP via sips,
-- parses pixels, and computes dHash.
-- Returns (hashString, nil) or (nil, errorMsg).
function M.computePhash(photo, ts)
    -- Render a tiny JPEG via LR's export pipeline
    local tinyPath, renderErr = M.renderImage(photo, ts .. "_ph", 32)
    if not tinyPath then
        return nil, "Phash render failed: " .. tostring(renderErr)
    end

    -- Use sips to resize to exactly 9x8 and convert to BMP
    local bmpPath = M.TEMP_DIR .. "/ai_sel_phash_" .. ts .. ".bmp"
    local sipsCmd = string.format(
        "sips -z 8 9 -s format bmp %s --out %s >/dev/null 2>&1",
        M.shellEscape(tinyPath), M.shellEscape(bmpPath)
    )
    local sipsExit = LrTasks.execute(sipsCmd)
    M.safeDelete(tinyPath)

    if sipsExit ~= 0 then
        M.safeDelete(bmpPath)
        return nil, "sips resize failed (exit " .. tostring(sipsExit) .. ")"
    end

    -- Parse BMP and compute dHash
    local rows, width, height = parseBmpGrayscale(bmpPath)
    M.safeDelete(bmpPath)

    if not rows or width < 9 or height < 8 then
        return nil, "BMP parse failed or unexpected dimensions"
    end

    local hash = computeDhash(rows)
    if not hash then
        return nil, "dHash computation failed"
    end

    return hash, nil
end

-- ── Story mode: text-only API functions ─────────────────────────────────
-- These mirror queryOllama/queryClaude but send text-only prompts (no images).
-- Used by story mode to send a metadata summary and get back a narrative selection.

M.STORY_PROMPT_TEMPLATE = [[You are an expert photo editor building a curated photo %PRESET_NAME% selection.

## Story Guidelines
%GUIDELINES%

%CUSTOM_INSTRUCTIONS%

## Task
From the photo metadata below, select exactly %TARGET_COUNT% photos that best tell this story.
Return ONLY a JSON array of objects, each with:
- id: the photo ID from the metadata
- position: sequence number (1 = first in story, 2 = second, etc.)
- story_note: 5-15 word editorial note explaining why this photo is here and its role in the story

## Constraints
- Select EXACTLY %TARGET_COUNT% photos. No more, no fewer.
- Reference photos ONLY by their "id" field from the metadata below.
- Every ID in your response must exist in the metadata.
- %CHRONOLOGICAL_CONSTRAINT%
- Ensure variety in narrative roles — don't select all the same type.
- %PEOPLE_CONSTRAINT%
- Distribute selections across the full timeline, not just the beginning or end.
- Prefer higher composite scores when choosing between similar candidates.

## Photo Metadata
%METADATA_JSON%

Return ONLY the JSON array. No explanation, no markdown, no commentary.]]

function M.queryOllamaText(prompt, modelName, ollamaUrl, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
    local encodeOk, body = pcall(json.encode, {
        model    = modelName,
        stream   = false,
        messages = {{
            role    = "user",
            content = prompt,
        }}
    })
    if not encodeOk then return nil, "JSON encode failed: " .. tostring(body) end

    local tmpCfg = M.TEMP_DIR .. "/ai_sel_cfg_" .. ts .. ".txt"
    local tmpIn  = M.TEMP_DIR .. "/ai_sel_req_" .. ts .. ".json"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_resp_" .. ts .. ".json"

    if not M.writeCurlConfig(tmpCfg, ollamaUrl .. "/api/chat",
            { "Content-Type: application/json" }, timeoutSecs) then
        return nil, "Could not write curl config file"
    end

    local fh = io.open(tmpIn, "w")
    if not fh then return nil, "Could not write temp file: " .. tmpIn end
    fh:write(body); fh:close()

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, 0, timeoutSecs)
    if not result then return nil, err end

    local ok, decoded = pcall(function() return json.decode(result) end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse Ollama response: " .. tostring(result):sub(1, 200)
    end
    if not (decoded.message and decoded.message.content) then
        return nil, "Unexpected Ollama response: " .. tostring(result):sub(1, 200)
    end

    return decoded.message.content, nil
end

function M.queryClaudeText(prompt, claudeModel, apiKey, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
    local encodeOk, body = pcall(json.encode, {
        model      = claudeModel,
        max_tokens = 8192,
        messages   = {{
            role    = "user",
            content = prompt,
        }}
    })
    if not encodeOk then return nil, "JSON encode failed: " .. tostring(body) end

    local cleanKey = apiKey:gsub("%s+", "")

    local tmpCfg = M.TEMP_DIR .. "/ai_sel_cfg_" .. ts .. ".txt"
    local tmpIn  = M.TEMP_DIR .. "/ai_sel_req_" .. ts .. ".json"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_resp_" .. ts .. ".json"

    if not M.writeCurlConfig(tmpCfg, "https://api.anthropic.com/v1/messages", {
        "x-api-key: " .. cleanKey,
        "anthropic-version: 2023-06-01",
        "content-type: application/json",
    }, timeoutSecs) then
        return nil, "Could not write curl config file"
    end

    local fh = io.open(tmpIn, "w")
    if not fh then return nil, "Could not write temp file: " .. tmpIn end
    fh:write(body); fh:close()

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, 0, timeoutSecs)
    if not result then return nil, err end

    local ok, decoded = pcall(function() return json.decode(result) end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse Claude response: " .. tostring(result):sub(1, 200)
    end

    if decoded.error then
        return nil, "Claude API error: " .. (decoded.error.message or "Unknown")
    end

    if decoded.content and type(decoded.content) == "table" then
        for _, block in ipairs(decoded.content) do
            if block.type == "text" and block.text then
                return block.text, nil
            end
        end
    end

    return nil, "Unexpected Claude response: " .. tostring(result):sub(1, 200)
end

-- ── Parse story mode AI response ────────────────────────────────────────
-- Expects a JSON array of { id, position, story_note }.
-- Validates all IDs exist in the valid set and positions are sequential.
-- Returns (selectionArray, nil) or (nil, errorMsg).
function M.parseStoryResponse(raw, validIds)
    if not raw or raw == "" then
        return nil, "Empty response from model"
    end

    -- Try to extract JSON array from the response
    local jsonStr = nil

    -- Level 1: Direct parse
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == "table" then
        -- Could be the array directly, or wrapped in an object
        if #data > 0 and data[1].id then
            jsonStr = raw  -- it's already a valid array
            -- data is already parsed
        elseif data.selections and type(data.selections) == "table" then
            data = data.selections
        elseif data.photos and type(data.photos) == "table" then
            data = data.photos
        elseif data.results and type(data.results) == "table" then
            data = data.results
        end
    end

    -- Level 2: Extract from markdown code block
    if not (ok and type(data) == "table" and #data > 0) then
        -- Lua . doesn't match newlines; use a workaround with character classes
        local block = raw:match("```json%s*([\1-\127\128-\255]-)%s*```")
                   or raw:match("```%s*([\1-\127\128-\255]-)%s*```")
        if block then
            ok, data = pcall(json.decode, block)
        end
    end

    -- Level 3: Find JSON array in surrounding text
    -- Use find to locate [ and ] boundaries since Lua patterns don't match \n with .
    if not (ok and type(data) == "table" and #data > 0) then
        local arrStart = raw:find("%[")
        local arrEnd = raw:reverse():find("%]")
        if arrStart and arrEnd then
            arrEnd = #raw - arrEnd + 1  -- convert from reverse index
            local arrStr = raw:sub(arrStart, arrEnd)
            ok, data = pcall(json.decode, arrStr)
        end
    end

    if not ok or type(data) ~= "table" or #data == 0 then
        return nil, "Could not parse story response as JSON array: " .. raw:sub(1, 300)
    end

    -- Build valid ID lookup set
    local validSet = {}
    for _, id in ipairs(validIds) do
        validSet[tostring(id)] = true
    end

    -- Validate and normalize entries
    local result = {}
    local seenIds = {}
    for _, entry in ipairs(data) do
        local id = tostring(entry.id or "")
        if id ~= "" and validSet[id] and not seenIds[id] then
            seenIds[id] = true
            result[#result + 1] = {
                id         = id,
                position   = tonumber(entry.position) or (#result + 1),
                story_note = tostring(entry.story_note or entry.storyNote or entry.note or ""),
            }
        end
    end

    if #result == 0 then
        return nil, "No valid photo IDs found in story response"
    end

    -- Sort by position
    table.sort(result, function(a, b) return a.position < b.position end)

    -- Re-number positions sequentially (in case of gaps)
    for i, entry in ipairs(result) do
        entry.position = i
    end

    return result, nil
end

-- ── Face/people detection via catalog SQLite query ──────────────────────
-- Lightroom's SDK doesn't expose face data, but the catalog SQLite database
-- stores it. We query it read-only via macOS built-in sqlite3.
-- Returns a table mapping photo localIdentifier → { "PersonName", ... }
-- Only returns named people (confirmed face tags in LR's People view).
function M.queryFacePeople(catalog, photos)
    local catalogPath = catalog:getPath()
    if not catalogPath then return {} end

    -- Build a set of photo IDs we care about
    local idList = {}
    for _, photo in ipairs(photos) do
        idList[#idList + 1] = tostring(photo.localIdentifier)
    end

    if #idList == 0 then return {} end

    -- Query: join faces → keyword-face bridge → keywords (person type)
    -- Filter to only user-confirmed faces (userPick = 1 or userReject is null/0)
    local sql = string.format([[
SELECT f.image, k.name
FROM AgLibraryFace f
JOIN AgLibraryKeywordFace kf ON kf.face = f.id_local
JOIN AgLibraryKeyword k ON k.id_local = kf.tag
WHERE k.keywordType = 'person'
  AND (kf.userReject IS NULL OR kf.userReject = 0)
  AND f.image IN (%s);
]], table.concat(idList, ","))

    -- Write SQL to temp file to avoid shell escaping issues
    local sqlPath = M.TEMP_DIR .. "/ai_sel_faces.sql"
    local fh = io.open(sqlPath, "w")
    if not fh then return {} end
    fh:write(sql)
    fh:close()

    -- Execute read-only query via sqlite3
    local outPath = M.TEMP_DIR .. "/ai_sel_faces_out.txt"
    local cmd = string.format(
        "sqlite3 -readonly -separator '|' %s < %s > %s 2>/dev/null",
        M.shellEscape(catalogPath), M.shellEscape(sqlPath), M.shellEscape(outPath)
    )
    local exitCode = LrTasks.execute(cmd)
    M.safeDelete(sqlPath)

    if exitCode ~= 0 then
        M.safeDelete(outPath)
        return {}
    end

    -- Parse output: each line is "photoId|personName"
    local result = {}
    local outData = M.readBinaryFile(outPath)
    M.safeDelete(outPath)

    if not outData or outData == "" then return {} end

    for line in outData:gmatch("[^\r\n]+") do
        local photoId, personName = line:match("^(%d+)|(.+)$")
        if photoId and personName then
            local id = tonumber(photoId)
            if id then
                if not result[id] then result[id] = {} end
                -- Avoid duplicate names for the same photo
                local found = false
                for _, n in ipairs(result[id]) do
                    if n == personName then found = true; break end
                end
                if not found then
                    result[id][#result[id] + 1] = personName
                end
            end
        end
    end

    return result
end

return M
