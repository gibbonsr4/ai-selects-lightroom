--[[
  BatchStrategy.lua
  ─────────────────────────────────────────────────────────────────────────────
  Pure logic module for batch formation, carryover anchor selection, and
  provider-specific configuration.

  No UI, no API calls, no side effects. Safe to dofile() from ScorePhotos.lua.
--]]

local M = {}

-- ─── Provider-specific batch configuration ──────────────────────────────────

local PROVIDER_CONFIG = {
    ollama = {
        batchSize        = 4,
        maxAnchors       = 1,       -- high anchor only
        supportsSnapshot = false,
        scoringMaxTokens = 2048,
        synthesisMaxTokens = 4096,
        defaultTimeout   = 120,
    },
    claude = {
        batchSize        = 10,
        maxAnchors       = 2,       -- high + low
        supportsSnapshot = true,
        scoringMaxTokens = 4096,
        synthesisMaxTokens = 8192,
        defaultTimeout   = 180,
    },
    openai = {
        batchSize        = 10,
        maxAnchors       = 2,
        supportsSnapshot = true,
        scoringMaxTokens = 4096,
        synthesisMaxTokens = 8192,
        defaultTimeout   = 180,
    },
    gemini = {
        batchSize        = 10,
        maxAnchors       = 2,
        supportsSnapshot = true,
        scoringMaxTokens = 4096,
        synthesisMaxTokens = 8192,
        defaultTimeout   = 180,
    },
}

--- Get the full config table for a provider.
-- Falls back to cloud defaults if provider is unknown.
function M.getProviderConfig(provider)
    return PROVIDER_CONFIG[provider] or PROVIDER_CONFIG.claude
end

--- Get batch size for a provider, with optional user override.
-- @param provider  String: provider name
-- @param override  Number or nil: user-configured batch size (0 = auto)
function M.getBatchSize(provider, override)
    if override and override > 0 then
        return override
    end
    return M.getProviderConfig(provider).batchSize
end

--- Whether this provider supports snapshot generation in the scoring prompt.
function M.supportsSnapshots(provider)
    return M.getProviderConfig(provider).supportsSnapshot
end

--- Get max output tokens for a call type ("scoring" or "synthesis").
function M.getMaxTokens(provider, callType)
    local cfg = M.getProviderConfig(provider)
    if callType == "synthesis" then
        return cfg.synthesisMaxTokens
    end
    return cfg.scoringMaxTokens
end

--- Get the default timeout for a provider.
function M.getDefaultTimeout(provider)
    return M.getProviderConfig(provider).defaultTimeout
end

--- Max number of carryover anchors for a provider.
function M.getMaxAnchors(provider)
    return M.getProviderConfig(provider).maxAnchors
end

-- ─── Batch formation ────────────────────────────────────────────────────────

--- Sort photos by capture time and split into chronological batches.
-- @param photos  Array of LrPhoto objects (from catalog:getTargetPhotos())
-- @param provider  String: "ollama", "claude", "openai", "gemini"
-- @param batchSizeOverride  Number or nil: user-configured batch size (0 = auto)
-- @return Array of batches, where each batch is an array of LrPhoto objects
function M.formBatches(photos, provider, batchSizeOverride)
    local batchSize = M.getBatchSize(provider, batchSizeOverride)

    -- Pre-fetch capture times and filenames (getRawMetadata yields, can't call inside table.sort)
    local timeCache = {}
    local nameCache = {}
    for _, photo in ipairs(photos) do
        timeCache[photo] = photo:getRawMetadata('dateTimeOriginal')
        nameCache[photo] = photo:getFormattedMetadata('fileName') or ""
    end

    -- Sort by capture time, falling back to filename
    local sorted = {}
    for i, photo in ipairs(photos) do
        sorted[i] = photo
    end
    table.sort(sorted, function(a, b)
        local timeA = timeCache[a]
        local timeB = timeCache[b]
        if timeA and timeB then
            if timeA == timeB then
                return nameCache[a] < nameCache[b]  -- stable sort: break ties by filename
            end
            return timeA < timeB
        elseif timeA then
            return true
        elseif timeB then
            return false
        else
            return nameCache[a] < nameCache[b]
        end
    end)

    -- Split into batches
    local batches = {}
    local currentBatch = {}
    for _, photo in ipairs(sorted) do
        currentBatch[#currentBatch + 1] = photo
        if #currentBatch >= batchSize then
            batches[#batches + 1] = currentBatch
            currentBatch = {}
        end
    end
    -- Don't leave a tiny remainder batch — merge into previous if very small
    if #currentBatch > 0 then
        if #batches > 0 and #currentBatch <= 2 then
            -- Merge into last batch (e.g., 10+2 = 12 is fine)
            local lastBatch = batches[#batches]
            for _, photo in ipairs(currentBatch) do
                lastBatch[#lastBatch + 1] = photo
            end
        else
            batches[#batches + 1] = currentBatch
        end
    end

    return batches
end

-- ─── Carryover anchor selection ─────────────────────────────────────────────

--- Select carryover anchor photos from the previous batch's scored results.
-- Returns entries suitable for inclusion in the next batch's prompt.
--
-- @param previousScores  Array of score tables from the previous batch, each with:
--   { photo = LrPhoto, id = string, technical = number, composition = number,
--     emotion = number, moment = number, composite = number, content = string, ... }
-- @param provider  String: provider name (determines max anchors)
-- @return Array of anchor tables: { photo, id, scores = {technical, composition, emotion, moment},
--         composite, role = "high"|"low"|"mid" }
function M.selectAnchors(previousScores, provider)
    if not previousScores or #previousScores < 2 then
        return {}
    end

    local maxAnchors = M.getMaxAnchors(provider)

    -- Sort by composite score
    local sorted = {}
    for i, entry in ipairs(previousScores) do
        sorted[i] = entry
    end
    table.sort(sorted, function(a, b)
        return (a.composite or 0) > (b.composite or 0)
    end)

    local anchors = {}

    -- Always include the highest-scoring photo
    local high = sorted[1]
    anchors[#anchors + 1] = {
        photo     = high.photo,
        id        = high.id,
        scores    = {
            technical   = high.technical,
            composition = high.composition,
            emotion     = high.emotion,
            moment      = high.moment,
        },
        composite = high.composite,
        content   = high.content,
        role      = "high",
    }

    -- Include lowest if provider supports 2+ anchors
    if maxAnchors >= 2 and #sorted >= 2 then
        local low = sorted[#sorted]
        anchors[#anchors + 1] = {
            photo     = low.photo,
            id        = low.id,
            scores    = {
                technical   = low.technical,
                composition = low.composition,
                emotion     = low.emotion,
                moment      = low.moment,
            },
            composite = low.composite,
            content   = low.content,
            role      = "low",
        }
    end

    -- Include mid-range if provider supports 3 anchors and batch is large enough
    if maxAnchors >= 3 and #sorted >= 5 then
        local midIdx = math.floor(#sorted / 2)
        local mid = sorted[midIdx]
        anchors[#anchors + 1] = {
            photo     = mid.photo,
            id        = mid.id,
            scores    = {
                technical   = mid.technical,
                composition = mid.composition,
                emotion     = mid.emotion,
                moment      = mid.moment,
            },
            composite = mid.composite,
            content   = mid.content,
            role      = "mid",
        }
    end

    return anchors
end

-- ─── Composite score calculation ────────────────────────────────────────────

--- Weight presets for the Technical ↔ Creative emphasis slider.
-- The slider maps a 0-100 value to weight distributions.
-- 0 = full technical, 100 = full creative, 50 = balanced.

local WEIGHT_PRESETS = {
    -- [emphasis] = { technical, composition, emotion, moment }
    -- These are interpolated, not looked up directly.
    technical = { 0.35, 0.30, 0.20, 0.15 },
    balanced  = { 0.25, 0.25, 0.25, 0.25 },
    creative  = { 0.15, 0.20, 0.35, 0.30 },
}

--- Compute dimension weights from the emphasis slider (0-100).
-- 0 = maximum technical emphasis, 100 = maximum creative emphasis.
-- Linearly interpolates between technical and creative presets.
-- @param emphasis  Number 0-100
-- @return table { technical, composition, emotion, moment } summing to 1.0
function M.computeWeights(emphasis)
    local t = (emphasis or 50) / 100   -- normalize to 0-1
    local techW  = WEIGHT_PRESETS.technical
    local creatW = WEIGHT_PRESETS.creative

    return {
        technical   = techW[1] + (creatW[1] - techW[1]) * t,
        composition = techW[2] + (creatW[2] - techW[2]) * t,
        emotion     = techW[3] + (creatW[3] - techW[3]) * t,
        moment      = techW[4] + (creatW[4] - techW[4]) * t,
    }
end

--- Compute composite score from individual dimension scores and weights.
-- @param scores  table { technical = N, composition = N, emotion = N, moment = N }
-- @param weights table { technical = N, composition = N, emotion = N, moment = N }
-- @param eyeQuality  string: "good", "fair", "closed", "na"
-- @return number  composite score (1-10 range, may go slightly below due to penalty)
function M.computeComposite(scores, weights, eyeQuality)
    local base = (scores.technical or 5) * weights.technical
              + (scores.composition or 5) * weights.composition
              + (scores.emotion or 5) * weights.emotion
              + (scores.moment or 5) * weights.moment

    -- Eye quality penalty
    local eyeAdj = 0
    if eyeQuality == "closed" then
        eyeAdj = -1.5
    end

    return base + eyeAdj
end

return M
