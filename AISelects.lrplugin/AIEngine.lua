--[[
  AIEngine.lua
  ---------------------------------------------------------------------------
  Shared AI inference engine -- image rendering, API calls, score parsing.
  Used by ScorePhotos.lua and SelectPhotos.lua.
  Pure functions, no UI, no side effects beyond temp files.

  v2: Multi-image batch scoring, 4-dimension scores, story snapshots,
      synthesis prompt for story mode.
--]]

local LrApplication     = import 'LrApplication'
local LrDate            = import 'LrDate'
local LrExportSession   = import 'LrExportSession'
local LrFileUtils       = import 'LrFileUtils'
local LrPathUtils       = import 'LrPathUtils'
local LrTasks           = import 'LrTasks'

local json = dofile(_PLUGIN.path .. '/dkjson.lua')
local BatchStrategy = dofile(_PLUGIN.path .. '/BatchStrategy.lua')

local M = {}

-- == Constants ================================================================
M.TEMP_DIR = "/tmp"

-- Claude's base64 image limit is 5MB. Base64 is ~4/3 of raw, so raw limit ~3.75MB.
M.CLAUDE_MAX_RAW_BYTES = 3750000

-- Minimum image dimension -- images smaller than this won't produce useful scores
M.MIN_IMAGE_DIMENSION = 200

-- SUPPORTED_EXTS is checked before LrExportSession to give clear error messages
-- for unsupported formats (e.g. PSD, AI) instead of opaque render failures.
M.SUPPORTED_EXTS = {
    jpg = true, jpeg = true, png = true,
    tif = true, tiff = true, webp = true,
    heic = true, heif = true,
    -- RAW formats -- LrExportSession handles these natively
    cr2 = true, cr3 = true, nef = true, arw = true,
    raf = true, orf = true, rw2 = true, dng = true,
    pef = true, srw = true,
}

-- == Recommended vision models for Ollama =====================================
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

-- == Remote model list URL ====================================================
M.MODELS_JSON_URL =
    "https://raw.githubusercontent.com/gibbonsr4/ai-selects-lightroom/main/models.json"

-- == Nitpicky scale modifiers =================================================
-- Prepended to the batch scoring prompt to calibrate expectations.
local NITPICKY_CONTEXT = {
    consumer = "You are scoring a casual mixed-quality photo collection. "
        .. "Expect wide variance in quality. Be generous with everyday snapshots "
        .. "but harsh on truly bad shots. Many photos may be average (4-6) and that is fine.",

    enthusiast = "You are scoring an enthusiast photographer's collection. "
        .. "Generally decent quality throughout. Discriminate carefully between "
        .. "good and great. Average for this set is higher than average overall.",

    professional = "You are scoring pre-culled professional work. "
        .. "Everything here is at least competent. Fine discrimination is essential -- "
        .. "find the exceptional among the good. Do not give high scores just because "
        .. "there are no obvious flaws.",
}

-- == Batch scoring prompt builder =============================================
-- Builds the complete prompt for a multi-image batch scoring call.
-- @param photoIds      Array of string IDs for photos in this batch
-- @param timestamps    Array of string timestamps matching photoIds order
-- @param anchors       Array of anchor tables (from BatchStrategy.selectAnchors)
--                      or nil/empty for the first batch
-- @param nitpickyScale String: "consumer", "enthusiast", "professional"
-- @param includeSnapshot Boolean: whether to request a story snapshot
-- @return string  The complete prompt text
function M.buildBatchScoringPrompt(photoIds, timestamps, anchors, nitpickyScale, includeSnapshot)
    local parts = {}

    -- Section 1: System context with nitpicky modifier
    parts[#parts + 1] = "SCORING CONTEXT\n"
    parts[#parts + 1] = (NITPICKY_CONTEXT[nitpickyScale] or NITPICKY_CONTEXT.consumer)
    parts[#parts + 1] = "\n\n"

    -- Section 2: Anchor context (batches 2+)
    if anchors and #anchors > 0 then
        parts[#parts + 1] = "REFERENCE PHOTOS (already scored -- calibrate your scale against these):\n"
        for i, anchor in ipairs(anchors) do
            parts[#parts + 1] = string.format(
                "Anchor %d (%s): technical=%d, composition=%d, emotion=%d, moment=%d (composite=%.1f)",
                i, anchor.role,
                anchor.scores.technical, anchor.scores.composition,
                anchor.scores.emotion, anchor.scores.moment,
                anchor.composite
            )
            if anchor.content then
                parts[#parts + 1] = string.format(" — %s", anchor.content)
            end
            parts[#parts + 1] = "\n"
        end
        parts[#parts + 1] = "\n"
        parts[#parts + 1] = "Your scores for new photos must be CONSISTENT with these reference points. "
        parts[#parts + 1] = "A photo clearly better than the high anchor should score higher. "
        parts[#parts + 1] = "A photo clearly worse than the low anchor should score lower.\n\n"
    end

    -- Section 3: Photo list (positional — no IDs to confuse the model)
    parts[#parts + 1] = string.format("You will score %d NEW PHOTOS.\n", #photoIds)
    parts[#parts + 1] = "The photos are presented IN ORDER. Return your scores array in the SAME ORDER — "
    parts[#parts + 1] = "the first element in the scores array must be for the first photo, the second for the second photo, etc.\n"
    for i, id in ipairs(photoIds) do
        local ts = timestamps[i] or ""
        if ts ~= "" then
            parts[#parts + 1] = string.format("Photo %d: Timestamp %s\n", i, ts)
        else
            parts[#parts + 1] = string.format("Photo %d\n", i)
        end
    end
    parts[#parts + 1] = "\n"

    -- Section 4: Scoring instructions
    parts[#parts + 1] = [[SCORING INSTRUCTIONS
You are a photo editor doing a first-pass cull. Your job is to RANK these photos against each other so the best ones stand out and the weak ones sink. Scores that cluster together are useless — spread them out.

Rate each photo on four dimensions (1-10 scale):
- technical: Sharpness, exposure, noise, white balance. A blurry phone snap = 2. A well-exposed sharp image = 7-8. Only flawless technique = 9-10.
- composition: Framing, lighting, visual balance, depth of field usage. A centered snapshot with no thought = 2-3. Intentional framing = 6-7. Gallery-worthy composition = 9-10.
- emotion: Expression, gesture, mood, human connection, atmosphere. A static building with no feeling = 1-2. Pleasant but generic = 4-5. Makes you stop and feel something = 8-9.
- moment: Peak timing, decisive instant vs throwaway. A hotel room or empty scene = 1-2. Generic activity = 4-5. A perfectly caught split-second = 9-10.

Also provide for each photo:
- content: 15-20 word description. Include: main subject, action/pose, setting, notable expressions, compositional approach. Be specific enough that someone could identify this exact photo from the description alone. Example: "Two young men grinning proudly, each gripping end of large mahi-mahi on boat stern, bright midday sun, ocean behind"
- category: one of: landscape, portrait, wildlife, architecture, food, street, macro, event, nature, other
- eye_quality: for most prominent person (one of: good, fair, closed, na)
- reject: true ONLY if obviously bad (severe blur, badly exposed, accidental shot)

MANDATORY DISPERSION RULES:
1. The BEST photo in this batch must score 8+ in its strongest dimension.
2. The WORST photo in this batch must score 4 or below in its weakest dimension.
3. Every dimension must have at least 5 points of spread (max minus min >= 5).
4. No more than 2 photos may share the same score in any single dimension.
5. Static scenes (buildings, rooms, empty landscapes) get moment scores of 1-3. Do not inflate them.
6. If a photo has no people showing emotion, its emotion score should be 1-4, not 5.

THINK LIKE A MAGAZINE EDITOR: most photos in any collection are mediocre. Only a few are great. Score accordingly — be harsh on the bottom and generous on the top.
]]

    -- Section 5: Snapshot request (cloud providers only)
    if includeSnapshot then
        parts[#parts + 1] = [[
STORY SNAPSHOT
Also return a snapshot describing this batch as a group -- what's happening, who's there, and the mood. This helps build a narrative across the full photo set.
]]
    end

    -- Section 6: Response format
    parts[#parts + 1] = "\nReturn ONLY valid JSON in this exact format:\n"

    if includeSnapshot then
        parts[#parts + 1] = [[{
  "scores": [
    {
      "technical": N,
      "composition": N,
      "emotion": N,
      "moment": N,
      "content": "15-20 word description",
      "category": "category_name",
      "eye_quality": "good|fair|closed|na",
      "reject": false
    }
  ],
  "snapshot": {
    "scene": "What is happening in these photos as a group",
    "people": ["Person/role descriptions visible"],
    "mood": "Overall emotional tone",
    "setting": "Physical environment/location",
    "action": "Primary activity or event",
    "transition_from_previous": "How this connects to what came before (or 'start' for first batch)"
  }
}

CRITICAL: The scores array MUST have exactly ]] .. #photoIds .. [[ elements, one per photo, in the SAME ORDER as the photos were presented.

]]
    else
        -- Ollama: simpler format, no snapshot
        parts[#parts + 1] = [[{
  "scores": [
    {
      "technical": N,
      "composition": N,
      "emotion": N,
      "moment": N,
      "content": "15-20 word description",
      "category": "category_name",
      "eye_quality": "good|fair|closed|na",
      "reject": false
    }
  ]
}

CRITICAL: The scores array MUST have exactly ]] .. #photoIds .. [[ elements, one per photo, in the SAME ORDER as the photos were presented.

]]
    end

    parts[#parts + 1] = "Do not explain your reasoning. Return only the JSON object."

    return table.concat(parts)
end

-- == Synthesis prompt template ================================================
-- Used for story mode: text-only call with event blocks + photo metadata.
-- Replaces the old STORY_PROMPT_TEMPLATE.
M.SYNTHESIS_PROMPT_TEMPLATE = [[You are an expert photo editor building a curated photo %PRESET_NAME% selection.

## Story Guidelines
%GUIDELINES%

%CUSTOM_INSTRUCTIONS%

## Event Timeline
The photos span these events (derived from visual analysis of the actual images):
%EVENT_BLOCKS%

## Task
From the scored photos below, select exactly %TARGET_COUNT% photos that best tell this story.
Return ONLY a JSON array of objects, each with:
- id: the photo ID from the metadata
- position: sequence number (1 = first in story, 2 = second, etc.)
- beat: which story event/moment this photo represents
- role: the narrative function (scene_setter, character_moment, action, detail, transition, closing, establishing, emotional_peak)
- note: 5-15 word editorial note explaining why this photo belongs here
- alternates: array of 1-2 alternate photo IDs that could substitute (for possible refinement)

## Constraints
- Select EXACTLY %TARGET_COUNT% photos. No more, no fewer.
- Reference photos ONLY by their "id" field from the metadata below.
- Every ID in your response must exist in the metadata.
- %CHRONOLOGICAL_CONSTRAINT%
- Ensure variety in narrative roles -- don't select all the same type.
- %PEOPLE_CONSTRAINT%
- Distribute selections across the full timeline and across events.
- Prefer higher composite scores when choosing between similar candidates.
- For each selection, suggest 1-2 alternates that could fill the same story role.

## Scored Photo Metadata
%METADATA_JSON%

Return ONLY the JSON array. No explanation, no markdown, no commentary.]]

-- == Pass 2 refinement prompt template ========================================
-- Used for focused per-beat comparisons in story mode.
M.PASS2_PROMPT_TEMPLATE = [[You are comparing photos for a specific story moment.

Story beat: %BEAT%
Narrative role: %ROLE%
Editorial note: %NOTE%

You are looking at %NUM_PHOTOS% photos. The first is the current selection, the rest are alternates.
Which photo BEST serves as the %ROLE% for this moment: "%BEAT%"?

Consider:
- How well does each photo capture this specific moment?
- Which has stronger emotional resonance for this story beat?
- Which better serves the narrative flow?

Return ONLY a JSON object:
{"selected_id": "the_best_photo_id", "reason": "10-word explanation"}]]


-- == Base64 encoder ===========================================================
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

-- == File & string helpers ====================================================
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
function M.shellEscape(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- == Ollama status helpers ====================================================
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

-- == Image rendering via LrExportSession ======================================
-- Uses Lightroom's own render pipeline. Handles every format LR can open
-- (RAW, HEIC, PSD, TIFF, etc.) and respects Develop adjustments.
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

-- == Prepare image for API ====================================================
-- Renders via LrExportSession, reads, base64-encodes.
-- Optional renderSize overrides provider defaults (used for batch scoring).
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
    elseif provider == "openai" or provider == "gemini" then
        renderDim = 1024
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

-- == Batch response parsing ===================================================

-- Normalize a single photo's score entry from the batch response.
function M.normalizeScores(data)
    -- Validate eye_quality against allowed values
    local eyeVal = tostring(data.eye_quality or "na"):lower()
    local validEye = { good = true, fair = true, closed = true, na = true }
    if not validEye[eyeVal] then eyeVal = "na" end

    -- Validate category against closed list
    local catVal = tostring(data.category or data.dominated_by or "other"):lower()
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
        composition    = math.max(1, math.min(10, tonumber(data.composition) or 5)),
        emotion        = math.max(1, math.min(10, tonumber(data.emotion) or 5)),
        moment         = math.max(1, math.min(10, tonumber(data.moment) or 5)),
        content        = tostring(data.content or "unknown"),
        category       = catVal,
        narrative_role = roleVal,
        eye_quality    = eyeVal,
        reject         = (data.reject == true or data.reject == "true"),
    }
end

-- Parse a batch scoring response.
-- Expects JSON: { "scores": [...], "snapshot": {...} }
-- Returns (scoresArray, snapshot, nil) or (nil, nil, errorMsg).
-- Scores are returned IN ORDER — caller maps by position, not by ID.
function M.parseBatchResponse(raw)
    if not raw or raw == "" then
        return nil, nil, "Empty response from model"
    end

    local ok, data

    -- Level 1: Direct JSON parse
    ok, data = pcall(json.decode, raw)

    -- Level 2: Extract JSON from markdown code block
    if not (ok and type(data) == "table") then
        local block = raw:match("```json%s*([\1-\127\128-\255]-)%s*```")
                   or raw:match("```%s*([\1-\127\128-\255]-)%s*```")
        if block then
            ok, data = pcall(json.decode, block)
        end
    end

    -- Level 3: Find JSON object in surrounding text
    if not (ok and type(data) == "table") then
        local objStart = raw:find("{")
        local objEnd = raw:reverse():find("}")
        if objStart and objEnd then
            objEnd = #raw - objEnd + 1
            local objStr = raw:sub(objStart, objEnd)
            ok, data = pcall(json.decode, objStr)
        end
    end

    if not ok or type(data) ~= "table" then
        return nil, nil, "Could not parse batch response as JSON: " .. raw:sub(1, 300)
    end

    -- Extract scores array — could be data.scores or data itself if it's an array
    local scoresRaw = data.scores
    if not scoresRaw and #data > 0 and data[1] then
        scoresRaw = data  -- response is just the scores array directly
    end

    if not scoresRaw or type(scoresRaw) ~= "table" or #scoresRaw == 0 then
        return nil, nil, "No scores array in batch response: " .. raw:sub(1, 300)
    end

    -- Normalize each score entry, preserving array order (positional mapping)
    local scores = {}
    for _, entry in ipairs(scoresRaw) do
        scores[#scores + 1] = M.normalizeScores(entry)
    end

    if #scores == 0 then
        return nil, nil, "No valid scores found in batch response"
    end

    -- Extract snapshot (may be nil for Ollama)
    local snapshot = data.snapshot

    return scores, snapshot, nil
end

-- == curl helper ==============================================================
-- Writes a curl config file with headers/URL/method, then invokes curl with
-- only controlled temp file paths on the command line. Prevents shell injection.
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
                detail = detail .. " Timeout -- increase timeout or use a faster model."
            elseif curlCode == 7 then
                detail = detail .. " Could not connect."
            end
        end
        return nil, detail
    end

    return result, nil
end

-- == Multi-image batch query: Ollama ==========================================
-- Ollama's /api/chat supports multiple images in the images array.
-- Smaller batches (4-5), no snapshot, simplified prompt.
function M.queryOllamaBatch(images, prompt, modelName, ollamaUrl, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))

    -- Build images array (base64 strings)
    local imgArray = {}
    local totalSize = 0
    for _, img in ipairs(images) do
        imgArray[#imgArray + 1] = img.base64
        totalSize = totalSize + img.fileSize
    end

    local encodeOk, body = pcall(json.encode, {
        model    = modelName,
        stream   = false,
        messages = {{
            role    = "user",
            content = prompt,
            images  = imgArray,
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

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, totalSize, timeoutSecs)
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

-- == Multi-image batch query: Claude ==========================================
-- Claude uses interleaved image + text content blocks.
-- Anchor images come first (labeled), then new photos (labeled), then the prompt.
function M.queryClaudeBatch(images, imageLabels, anchorImages, anchorLabels,
                            prompt, claudeModel, apiKey, maxTokens, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))

    -- Build interleaved content blocks
    local content = {}
    local totalSize = 0

    -- Anchor images first (if any) — label BEFORE image for reliable association
    if anchorImages then
        content[#content + 1] = {
            type = "text",
            text = "=== REFERENCE ANCHORS (already scored, DO NOT re-score) ===",
        }
        for i, img in ipairs(anchorImages) do
            content[#content + 1] = {
                type = "text",
                text = anchorLabels[i] or string.format("[Anchor %d]", i),
            }
            content[#content + 1] = {
                type   = "image",
                source = {
                    type       = "base64",
                    media_type = "image/jpeg",
                    data       = img.base64,
                },
            }
            totalSize = totalSize + img.fileSize
        end
        content[#content + 1] = {
            type = "text",
            text = "=== NEW PHOTOS TO SCORE (return scores for these only) ===",
        }
    end

    -- New photos — label BEFORE image so model reads ID before seeing the photo
    for i, img in ipairs(images) do
        content[#content + 1] = {
            type = "text",
            text = imageLabels[i] or string.format("[Photo %d]", i),
        }
        content[#content + 1] = {
            type   = "image",
            source = {
                type       = "base64",
                media_type = "image/jpeg",
                data       = img.base64,
            },
        }
        totalSize = totalSize + img.fileSize
    end

    -- Final text block: the scoring prompt
    content[#content + 1] = {
        type = "text",
        text = prompt,
    }

    local encodeOk, body = pcall(json.encode, {
        model      = claudeModel,
        max_tokens = maxTokens or 4096,
        messages   = {{
            role    = "user",
            content = content,
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

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, totalSize, timeoutSecs)
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

-- == Multi-image batch query: OpenAI ==========================================
-- OpenAI uses image_url content blocks with base64 data URIs.
function M.queryOpenAIBatch(images, imageLabels, anchorImages, anchorLabels,
                            prompt, openaiModel, apiKey, maxTokens, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))

    local content = {}
    local totalSize = 0

    -- Anchor images first — label BEFORE image for reliable association
    if anchorImages then
        content[#content + 1] = {
            type = "text",
            text = "=== REFERENCE ANCHORS (already scored, DO NOT re-score) ===",
        }
        for i, img in ipairs(anchorImages) do
            content[#content + 1] = {
                type = "text",
                text = anchorLabels[i] or string.format("[Anchor %d]", i),
            }
            content[#content + 1] = {
                type      = "image_url",
                image_url = {
                    url    = "data:image/jpeg;base64," .. img.base64,
                    detail = "low",
                },
            }
            totalSize = totalSize + img.fileSize
        end
        content[#content + 1] = {
            type = "text",
            text = "=== NEW PHOTOS TO SCORE (return scores for these only) ===",
        }
    end

    -- New photos — label BEFORE image
    for i, img in ipairs(images) do
        content[#content + 1] = {
            type = "text",
            text = imageLabels[i] or string.format("[Photo %d]", i),
        }
        content[#content + 1] = {
            type      = "image_url",
            image_url = {
                url    = "data:image/jpeg;base64," .. img.base64,
                detail = "low",
            },
        }
        totalSize = totalSize + img.fileSize
    end

    -- Prompt as final text block
    content[#content + 1] = {
        type = "text",
        text = prompt,
    }

    local encodeOk, body = pcall(json.encode, {
        model      = openaiModel,
        max_tokens = maxTokens or 4096,
        messages   = {{
            role    = "user",
            content = content,
        }}
    })
    if not encodeOk then return nil, "JSON encode failed: " .. tostring(body) end

    local cleanKey = apiKey:gsub("%s+", "")

    local tmpCfg = M.TEMP_DIR .. "/ai_sel_cfg_" .. ts .. ".txt"
    local tmpIn  = M.TEMP_DIR .. "/ai_sel_req_" .. ts .. ".json"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_resp_" .. ts .. ".json"

    if not M.writeCurlConfig(tmpCfg, "https://api.openai.com/v1/chat/completions", {
        "Authorization: Bearer " .. cleanKey,
        "Content-Type: application/json",
    }, timeoutSecs) then
        return nil, "Could not write curl config file"
    end

    local fh = io.open(tmpIn, "w")
    if not fh then return nil, "Could not write temp file: " .. tmpIn end
    fh:write(body); fh:close()

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, totalSize, timeoutSecs)
    if not result then return nil, err end

    local ok, decoded = pcall(function() return json.decode(result) end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse OpenAI response: " .. tostring(result):sub(1, 200)
    end

    if decoded.error then
        return nil, "OpenAI API error: " .. (decoded.error.message or "Unknown")
    end

    if decoded.choices and decoded.choices[1] and decoded.choices[1].message then
        return decoded.choices[1].message.content, nil
    end

    return nil, "Unexpected OpenAI response: " .. tostring(result):sub(1, 200)
end

-- == Multi-image batch query: Gemini ==========================================
-- Gemini uses inline_data parts interleaved with text parts.
function M.queryGeminiBatch(images, imageLabels, anchorImages, anchorLabels,
                            prompt, geminiModel, apiKey, maxTokens, timeoutSecs)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))

    local parts = {}
    local totalSize = 0

    -- Anchor images first — label BEFORE image for reliable association
    if anchorImages then
        parts[#parts + 1] = {
            text = "=== REFERENCE ANCHORS (already scored, DO NOT re-score) ===",
        }
        for i, img in ipairs(anchorImages) do
            parts[#parts + 1] = {
                text = anchorLabels[i] or string.format("[Anchor %d]", i),
            }
            parts[#parts + 1] = {
                inline_data = {
                    mime_type = "image/jpeg",
                    data      = img.base64,
                },
            }
            totalSize = totalSize + img.fileSize
        end
        parts[#parts + 1] = {
            text = "=== NEW PHOTOS TO SCORE (return scores for these only) ===",
        }
    end

    -- New photos — label BEFORE image
    for i, img in ipairs(images) do
        parts[#parts + 1] = {
            text = imageLabels[i] or string.format("[Photo %d]", i),
        }
        parts[#parts + 1] = {
            inline_data = {
                mime_type = "image/jpeg",
                data      = img.base64,
            },
        }
        totalSize = totalSize + img.fileSize
    end

    -- Prompt as final text part
    parts[#parts + 1] = {
        text = prompt,
    }

    local encodeOk, body = pcall(json.encode, {
        contents = {{
            parts = parts,
        }},
        generationConfig = {
            maxOutputTokens = maxTokens or 4096,
        },
    })
    if not encodeOk then return nil, "JSON encode failed: " .. tostring(body) end

    local cleanKey = apiKey:gsub("%s+", "")
    local url = string.format(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
        geminiModel, cleanKey
    )

    local tmpCfg = M.TEMP_DIR .. "/ai_sel_cfg_" .. ts .. ".txt"
    local tmpIn  = M.TEMP_DIR .. "/ai_sel_req_" .. ts .. ".json"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_resp_" .. ts .. ".json"

    if not M.writeCurlConfig(tmpCfg, url, {
        "Content-Type: application/json",
    }, timeoutSecs) then
        return nil, "Could not write curl config file"
    end

    local fh = io.open(tmpIn, "w")
    if not fh then return nil, "Could not write temp file: " .. tmpIn end
    fh:write(body); fh:close()

    local result, err = M.curlPost(tmpCfg, tmpIn, tmpOut, totalSize, timeoutSecs)
    if not result then return nil, err end

    local ok, decoded = pcall(function() return json.decode(result) end)
    if not ok or type(decoded) ~= "table" then
        return nil, "Could not parse Gemini response: " .. tostring(result):sub(1, 200)
    end

    if decoded.error then
        return nil, "Gemini API error: " .. (decoded.error.message or "Unknown")
    end

    if decoded.candidates and decoded.candidates[1]
       and decoded.candidates[1].content
       and decoded.candidates[1].content.parts then
        for _, part in ipairs(decoded.candidates[1].content.parts) do
            if part.text then
                return part.text, nil
            end
        end
    end

    return nil, "Unexpected Gemini response: " .. tostring(result):sub(1, 200)
end

-- == Unified batch query dispatcher ===========================================
-- Calls the appropriate provider's batch query function.
-- @param images       Array of {base64, fileSize} for new photos
-- @param imageLabels  Array of label strings matching images
-- @param anchorImages Array of {base64, fileSize} for anchor photos (or nil)
-- @param anchorLabels Array of label strings for anchors (or nil)
-- @param prompt       The scoring prompt text
-- @param prefs        Preferences table (provider, model, apiKey, etc.)
-- @param maxTokens    Max output tokens
-- @return (rawText, nil) or (nil, errorMsg)
function M.queryBatch(images, imageLabels, anchorImages, anchorLabels, prompt, prefs, maxTokens)
    local provider = prefs.provider
    local timeout  = prefs.timeoutSecs or BatchStrategy.getDefaultTimeout(provider)

    if provider == "ollama" then
        -- Ollama: simpler path, no anchor images in the API call
        -- (anchors are described in the prompt text only, not as images,
        --  to keep the batch small for local models)
        return M.queryOllamaBatch(images, prompt, prefs.model, prefs.ollamaUrl, timeout)
    elseif provider == "claude" then
        return M.queryClaudeBatch(images, imageLabels, anchorImages, anchorLabels,
            prompt, prefs.claudeModel, prefs.claudeApiKey, maxTokens, timeout)
    elseif provider == "openai" then
        return M.queryOpenAIBatch(images, imageLabels, anchorImages, anchorLabels,
            prompt, prefs.openaiModel, prefs.openaiApiKey, maxTokens, timeout)
    elseif provider == "gemini" then
        return M.queryGeminiBatch(images, imageLabels, anchorImages, anchorLabels,
            prompt, prefs.geminiModel, prefs.geminiApiKey, maxTokens, timeout)
    else
        return nil, "Unknown provider: " .. tostring(provider)
    end
end

-- == Text-only API functions (for synthesis and Pass 2) =======================
-- These send text-only prompts (no images). Used for story synthesis and
-- Pass 2 refinement calls.

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

function M.queryClaudeText(prompt, claudeModel, apiKey, timeoutSecs, maxTokens)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
    local encodeOk, body = pcall(json.encode, {
        model      = claudeModel,
        max_tokens = maxTokens or 8192,
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

function M.queryOpenAIText(prompt, openaiModel, apiKey, timeoutSecs, maxTokens)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
    local encodeOk, body = pcall(json.encode, {
        model      = openaiModel,
        max_tokens = maxTokens or 8192,
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

    if not M.writeCurlConfig(tmpCfg, "https://api.openai.com/v1/chat/completions", {
        "Authorization: Bearer " .. cleanKey,
        "Content-Type: application/json",
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
        return nil, "Could not parse OpenAI response: " .. tostring(result):sub(1, 200)
    end

    if decoded.error then
        return nil, "OpenAI API error: " .. (decoded.error.message or "Unknown")
    end

    if decoded.choices and decoded.choices[1] and decoded.choices[1].message then
        return decoded.choices[1].message.content, nil
    end

    return nil, "Unexpected OpenAI response: " .. tostring(result):sub(1, 200)
end

function M.queryGeminiText(prompt, geminiModel, apiKey, timeoutSecs, maxTokens)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))
    local encodeOk, body = pcall(json.encode, {
        contents = {{
            parts = {
                { text = prompt },
            },
        }},
        generationConfig = {
            maxOutputTokens = maxTokens or 8192,
        },
    })
    if not encodeOk then return nil, "JSON encode failed: " .. tostring(body) end

    local cleanKey = apiKey:gsub("%s+", "")
    local url = string.format(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s",
        geminiModel, cleanKey
    )

    local tmpCfg = M.TEMP_DIR .. "/ai_sel_cfg_" .. ts .. ".txt"
    local tmpIn  = M.TEMP_DIR .. "/ai_sel_req_" .. ts .. ".json"
    local tmpOut = M.TEMP_DIR .. "/ai_sel_resp_" .. ts .. ".json"

    if not M.writeCurlConfig(tmpCfg, url, {
        "Content-Type: application/json",
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
        return nil, "Could not parse Gemini response: " .. tostring(result):sub(1, 200)
    end

    if decoded.error then
        return nil, "Gemini API error: " .. (decoded.error.message or "Unknown")
    end

    if decoded.candidates and decoded.candidates[1]
       and decoded.candidates[1].content
       and decoded.candidates[1].content.parts then
        for _, part in ipairs(decoded.candidates[1].content.parts) do
            if part.text then
                return part.text, nil
            end
        end
    end

    return nil, "Unexpected Gemini response: " .. tostring(result):sub(1, 200)
end

-- == Unified text query dispatcher ============================================
-- Calls the appropriate provider's text-only function.
-- @param prompt     The prompt text
-- @param prefs      Preferences table
-- @param maxTokens  Max output tokens (optional, defaults per provider)
-- @return (rawText, nil) or (nil, errorMsg)
function M.queryText(prompt, prefs, maxTokens)
    local provider = prefs.provider
    local timeout  = prefs.timeoutSecs or BatchStrategy.getDefaultTimeout(provider)

    if provider == "ollama" then
        return M.queryOllamaText(prompt, prefs.model, prefs.ollamaUrl, timeout)
    elseif provider == "claude" then
        return M.queryClaudeText(prompt, prefs.claudeModel, prefs.claudeApiKey, timeout, maxTokens)
    elseif provider == "openai" then
        return M.queryOpenAIText(prompt, prefs.openaiModel, prefs.openaiApiKey, timeout, maxTokens)
    elseif provider == "gemini" then
        return M.queryGeminiText(prompt, prefs.geminiModel, prefs.geminiApiKey, timeout, maxTokens)
    else
        return nil, "Unknown provider: " .. tostring(provider)
    end
end

-- == Pass 2: focused image comparison =========================================
-- Sends 2-3 images for a specific story beat and asks which is best.
-- @param images     Array of {base64, fileSize} (primary + alternates)
-- @param imageIds   Array of string IDs matching images
-- @param beat       String: the story beat description
-- @param role       String: the narrative role
-- @param note       String: the editorial note
-- @param prefs      Preferences table
-- @return (selectedId, nil) or (nil, errorMsg)
function M.queryPass2(images, imageIds, beat, role, note, prefs)
    local prompt = M.PASS2_PROMPT_TEMPLATE
    prompt = prompt:gsub("%%BEAT%%", beat or "")
    prompt = prompt:gsub("%%ROLE%%", role or "")
    prompt = prompt:gsub("%%NOTE%%", note or "")
    prompt = prompt:gsub("%%NUM_PHOTOS%%", tostring(#images))

    local imageLabels = {}
    for i, id in ipairs(imageIds) do
        if i == 1 then
            imageLabels[i] = string.format("[Photo %d - Current Selection] ID: %s", i, id)
        else
            imageLabels[i] = string.format("[Photo %d - Alternate] ID: %s", i, id)
        end
    end

    local provider = prefs.provider
    local timeout  = prefs.timeoutSecs or BatchStrategy.getDefaultTimeout(provider)
    local maxTokens = 256  -- small response needed

    local rawText, err

    if provider == "claude" then
        rawText, err = M.queryClaudeBatch(images, imageLabels, nil, nil,
            prompt, prefs.claudeModel, prefs.claudeApiKey, maxTokens, timeout)
    elseif provider == "openai" then
        rawText, err = M.queryOpenAIBatch(images, imageLabels, nil, nil,
            prompt, prefs.openaiModel, prefs.openaiApiKey, maxTokens, timeout)
    elseif provider == "gemini" then
        rawText, err = M.queryGeminiBatch(images, imageLabels, nil, nil,
            prompt, prefs.geminiModel, prefs.geminiApiKey, maxTokens, timeout)
    else
        return nil, "Pass 2 not supported for provider: " .. tostring(provider)
    end

    if not rawText then return nil, err end

    -- Parse response: {"selected_id": "...", "reason": "..."}
    local ok, data = pcall(json.decode, rawText)
    if not ok or type(data) ~= "table" then
        -- Try extracting from markdown block
        local block = rawText:match("```json%s*([\1-\127\128-\255]-)%s*```")
                   or rawText:match("```%s*([\1-\127\128-\255]-)%s*```")
        if block then
            ok, data = pcall(json.decode, block)
        end
    end
    if not ok or type(data) ~= "table" then
        -- Try finding JSON object
        local objStr = rawText:match("%{.-%}")
        if objStr then
            ok, data = pcall(json.decode, objStr)
        end
    end

    if ok and data and data.selected_id then
        -- Validate the selected ID is one of the candidates
        for _, id in ipairs(imageIds) do
            if tostring(data.selected_id) == id then
                return id, nil
            end
        end
        return nil, "Pass 2 returned invalid ID: " .. tostring(data.selected_id)
    end

    return nil, "Could not parse Pass 2 response: " .. rawText:sub(1, 200)
end

-- == Parse story/synthesis response ===========================================
-- Expects a JSON array of { id, position, beat, role, note, alternates }.
-- Validates all IDs exist in the valid set and positions are sequential.
-- Returns (selectionArray, nil) or (nil, errorMsg).
function M.parseStoryResponse(raw, validIds)
    if not raw or raw == "" then
        return nil, "Empty response from model"
    end

    -- Try to extract JSON array from the response
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == "table" then
        -- Could be the array directly, or wrapped in an object
        if #data > 0 and data[1].id then
            -- it's already a valid array
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
        local block = raw:match("```json%s*([\1-\127\128-\255]-)%s*```")
                   or raw:match("```%s*([\1-\127\128-\255]-)%s*```")
        if block then
            ok, data = pcall(json.decode, block)
        end
    end

    -- Level 3: Find JSON array in surrounding text
    if not (ok and type(data) == "table" and #data > 0) then
        local arrStart = raw:find("%[")
        local arrEnd = raw:reverse():find("%]")
        if arrStart and arrEnd then
            arrEnd = #raw - arrEnd + 1
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
            -- Collect alternates, validating each
            local alts = {}
            if entry.alternates and type(entry.alternates) == "table" then
                for _, altId in ipairs(entry.alternates) do
                    local aid = tostring(altId)
                    if validSet[aid] and not seenIds[aid] then
                        alts[#alts + 1] = aid
                    end
                end
            end
            result[#result + 1] = {
                id         = id,
                position   = tonumber(entry.position) or (#result + 1),
                beat       = tostring(entry.beat or entry.story_note or ""),
                role       = tostring(entry.role or entry.narrative_role or "detail"),
                note       = tostring(entry.note or entry.story_note or entry.storyNote or ""),
                alternates = alts,
            }
        end
    end

    if #result == 0 then
        return nil, "No valid photo IDs found in story response"
    end

    -- Sort by position
    table.sort(result, function(a, b) return a.position < b.position end)

    -- Re-number positions sequentially
    for i, entry in ipairs(result) do
        entry.position = i
    end

    return result, nil
end

-- == Perceptual hashing (dHash) via sips ======================================
-- Computes a 64-bit difference hash for visual duplicate detection.
-- Uses macOS built-in `sips` to resize to 9x8 BMP, then parses the BMP
-- pixel data in pure Lua. No external dependencies.

local function parseBmpGrayscale(path)
    local data = M.readBinaryFile(path)
    if not data or #data < 54 then return nil end

    local function u32(offset)
        local b1, b2, b3, b4 = data:byte(offset, offset + 3)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    local function u16(offset)
        local b1, b2 = data:byte(offset, offset + 1)
        return b1 + b2 * 256
    end

    local pixelOffset = u32(11)
    local width       = u32(19)
    local height      = u32(23)
    local bpp         = u16(29)

    if bpp ~= 24 then return nil end

    local rowBytes = math.ceil(width * 3 / 4) * 4

    local rows = {}
    for y = 0, height - 1 do
        local row = {}
        local rowStart = pixelOffset + (height - 1 - y) * rowBytes
        for x = 0, width - 1 do
            local pixStart = rowStart + x * 3 + 1
            if pixStart + 2 > #data then return nil end
            local b, g, r = data:byte(pixStart, pixStart + 2)
            row[x + 1] = math.floor(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
        end
        rows[y + 1] = row
    end

    return rows, width, height
end

local function computeDhash(rows)
    local bits = {}
    for y = 1, 8 do
        local row = rows[y]
        if not row then return nil end
        for x = 1, 8 do
            bits[#bits + 1] = (row[x] > row[x + 1]) and 1 or 0
        end
    end

    local hex = {}
    for i = 1, 64, 4 do
        local nibble = bits[i] * 8 + bits[i+1] * 4 + bits[i+2] * 2 + bits[i+3]
        hex[#hex + 1] = string.format("%x", nibble)
    end
    return table.concat(hex)
end

function M.hashDistance(hash1, hash2)
    if not hash1 or not hash2 then return 64 end
    if #hash1 ~= #hash2 then return 64 end

    local distance = 0
    for i = 1, #hash1 do
        local a = tonumber(hash1:sub(i, i), 16) or 0
        local b = tonumber(hash2:sub(i, i), 16) or 0
        for bit = 0, 3 do
            local mask = 2 ^ bit
            local aBit = math.floor(a / mask) % 2
            local bBit = math.floor(b / mask) % 2
            if aBit ~= bBit then distance = distance + 1 end
        end
    end
    return distance
end

function M.computePhash(photo, ts)
    local tinyPath, renderErr = M.renderImage(photo, ts .. "_ph", 32)
    if not tinyPath then
        return nil, "Phash render failed: " .. tostring(renderErr)
    end

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

-- == Face/people detection via catalog SQLite query ============================
-- Lightroom's SDK doesn't expose face data, but the catalog SQLite database
-- stores it. We query it read-only via macOS built-in sqlite3.
function M.queryFacePeople(catalog, photos)
    local catalogPath = catalog:getPath()
    if not catalogPath then return {} end

    local idList = {}
    for _, photo in ipairs(photos) do
        idList[#idList + 1] = tostring(photo.localIdentifier)
    end

    if #idList == 0 then return {} end

    local sql = string.format([[
SELECT f.image, k.name
FROM AgLibraryFace f
JOIN AgLibraryKeywordFace kf ON kf.face = f.id_local
JOIN AgLibraryKeyword k ON k.id_local = kf.tag
WHERE k.keywordType = 'person'
  AND (kf.userReject IS NULL OR kf.userReject = 0)
  AND f.image IN (%s);
]], table.concat(idList, ","))

    local sqlPath = M.TEMP_DIR .. "/ai_sel_faces.sql"
    local fh = io.open(sqlPath, "w")
    if not fh then return {} end
    fh:write(sql)
    fh:close()

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
