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

-- == Cost tracking ============================================================
-- Per-provider pricing (USD per 1M tokens). Updated as of 2025-03.
-- Vision input tokens are estimated from image size (provider-specific).
local PRICING = {
    claude = {
        -- Claude Haiku 3.5
        ["claude-haiku-4-5-20251001"] = { input = 0.80, output = 4.00 },
        -- Claude Sonnet
        ["claude-sonnet-4-20250514"]  = { input = 3.00, output = 15.00 },
        -- Fallback for unknown Claude models
        _default                       = { input = 3.00, output = 15.00 },
    },
    openai = {
        ["gpt-4.1-mini"]  = { input = 0.40, output = 1.60 },
        ["gpt-4.1"]       = { input = 2.00, output = 8.00 },
        ["gpt-4.1-nano"]  = { input = 0.10, output = 0.40 },
        ["gpt-4o"]        = { input = 2.50, output = 10.00 },
        ["gpt-4o-mini"]   = { input = 0.15, output = 0.60 },
        _default           = { input = 2.50, output = 10.00 },
    },
    gemini = {
        ["gemini-2.5-flash"]   = { input = 0.15, output = 0.60 },
        ["gemini-2.5-pro"]     = { input = 1.25, output = 10.00 },
        ["gemini-2.0-flash"]   = { input = 0.10, output = 0.40 },
        _default                = { input = 0.15, output = 0.60 },
    },
}

-- Shared cost accumulator — reset per run via M.resetCostTracker()
local costTracker = {
    totalInputTokens  = 0,
    totalOutputTokens = 0,
    totalCost         = 0,
    callCount         = 0,
    breakdown         = {},  -- array of {pass, inputTokens, outputTokens, cost}
}

function M.resetCostTracker()
    costTracker.totalInputTokens  = 0
    costTracker.totalOutputTokens = 0
    costTracker.totalCost         = 0
    costTracker.callCount         = 0
    costTracker.breakdown         = {}
end

-- Get pricing for a provider + model
local function getPricing(provider, model)
    local providerPricing = PRICING[provider]
    if not providerPricing then return nil end
    return providerPricing[model] or providerPricing._default
end

-- Record usage from an API response. Called internally by query functions.
-- @param provider     "claude", "openai", "gemini"
-- @param model        Model name string
-- @param inputTokens  Number of input tokens
-- @param outputTokens Number of output tokens
-- @param passLabel    Optional string label (e.g., "Pass 1 batch 3", "Pass 4 beat 7")
local function recordUsage(provider, model, inputTokens, outputTokens, passLabel)
    if not inputTokens and not outputTokens then return end
    local inp = inputTokens or 0
    local out = outputTokens or 0

    costTracker.totalInputTokens  = costTracker.totalInputTokens  + inp
    costTracker.totalOutputTokens = costTracker.totalOutputTokens + out
    costTracker.callCount         = costTracker.callCount + 1

    local pricing = getPricing(provider, model)
    if pricing then
        local callCost = (inp * pricing.input + out * pricing.output) / 1000000
        costTracker.totalCost = costTracker.totalCost + callCost
        costTracker.breakdown[#costTracker.breakdown + 1] = {
            pass         = passLabel or ("call " .. costTracker.callCount),
            inputTokens  = inp,
            outputTokens = out,
            cost         = callCost,
        }
    end
end

-- Get current cost summary (for logging at milestones)
function M.getCostSummary()
    return {
        totalInputTokens  = costTracker.totalInputTokens,
        totalOutputTokens = costTracker.totalOutputTokens,
        totalCost         = costTracker.totalCost,
        callCount         = costTracker.callCount,
    }
end

-- Format cost for log display
function M.formatCost(cost)
    if cost < 0.01 then
        return string.format("$%.4f", cost)
    else
        return string.format("$%.2f", cost)
    end
end

-- Format a full cost summary line for logging
function M.formatCostSummary()
    local s = costTracker
    if s.callCount == 0 then return "No API calls made" end
    return string.format("%d API calls | %dk input + %dk output tokens | %s total cost",
        s.callCount,
        math.floor(s.totalInputTokens / 1000),
        math.floor(s.totalOutputTokens / 1000),
        M.formatCost(s.totalCost))
end


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
-- @param photoIds        Array of string IDs for photos in this batch
-- @param timestamps      Array of string timestamps matching photoIds order
-- @param exifData        Array of EXIF strings matching photoIds order
-- @param anchors         Array of anchor tables (from BatchStrategy.selectAnchors)
--                        or nil/empty for the first batch
-- @param nitpickyScale   String: "consumer", "enthusiast", "professional"
-- @param includeSnapshot Boolean: whether to request a story snapshot
-- @param preHints        Optional string: user-provided context hints
-- @param priorSnapshots  Optional array of snapshot tables from previous batches
-- @return string  The complete prompt text
function M.buildBatchScoringPrompt(photoIds, timestamps, exifData, anchors, nitpickyScale, includeSnapshot, preHints, priorSnapshots)
    local parts = {}

    -- Section 1: System context with nitpicky modifier
    parts[#parts + 1] = "SCORING CONTEXT\n"
    parts[#parts + 1] = (NITPICKY_CONTEXT[nitpickyScale] or NITPICKY_CONTEXT.consumer)
    parts[#parts + 1] = "\n\n"

    -- Pre-hints from user (optional context)
    if preHints and preHints ~= "" then
        parts[#parts + 1] = "PHOTOGRAPHER'S NOTES\n"
        parts[#parts + 1] = preHints .. "\n\n"
    end

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

    -- Section 2b: Prior batch snapshots (cumulative narrative context)
    if priorSnapshots and #priorSnapshots > 0 then
        parts[#parts + 1] = "STORY SO FAR (snapshots from previous batches — use for narrative context):\n"
        for i, snap in ipairs(priorSnapshots) do
            local snapParts = {}
            if snap.scene and snap.scene ~= "" then
                snapParts[#snapParts + 1] = snap.scene
            end
            if snap.action and snap.action ~= "" then
                snapParts[#snapParts + 1] = snap.action
            end
            if snap.people and type(snap.people) == "table" and #snap.people > 0 then
                snapParts[#snapParts + 1] = "People: " .. table.concat(snap.people, ", ")
            end
            if snap.mood and snap.mood ~= "" then
                snapParts[#snapParts + 1] = "Mood: " .. snap.mood
            end
            local timeStr = ""
            if snap.timeRange then
                timeStr = string.format(" (%s)", snap.timeRange.start or "")
            end
            parts[#parts + 1] = string.format("  Batch %d%s: %s\n",
                snap.batchIndex or i, timeStr, table.concat(snapParts, ". "))
        end
        parts[#parts + 1] = "\n"
    end

    -- Section 3: Photo list (positional — no IDs to confuse the model)
    parts[#parts + 1] = string.format("You will score %d NEW PHOTOS.\n", #photoIds)
    parts[#parts + 1] = "The photos are presented IN ORDER. Return your scores array in the SAME ORDER — "
    parts[#parts + 1] = "the first element in the scores array must be for the first photo, the second for the second photo, etc.\n"
    for i, id in ipairs(photoIds) do
        local ts = timestamps[i] or ""
        local exif = exifData and exifData[i] or ""
        local details = {}
        if ts ~= "" then details[#details + 1] = "Timestamp " .. ts end
        if exif ~= "" then details[#details + 1] = exif end
        if #details > 0 then
            parts[#parts + 1] = string.format("Photo %d: %s\n", i, table.concat(details, " | "))
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
-- == v3 Story Prepopulation prompt ============================================
-- Text-only call to synthesize batch snapshots + metadata into a natural-language
-- story summary that the user can edit in the mid-run dialog.
M.PREPOPULATE_PROMPT_TEMPLATE = [[Based on the following photo collection analysis, write a 3-4 sentence natural language summary that describes this photo collection as if you're describing it to the photographer. Write in second person ("you"). Make it feel like a conversation, not a data dump.

Batch snapshots (what the AI saw in each scoring batch):
%%SNAPSHOT_SUMMARIES%%

People identified: %%PEOPLE_SUMMARY%%
Categories: %%CATEGORY_SUMMARY%%
Time range: %%TIME_RANGE%%
Total photos: %%TOTAL_PHOTOS%%
%%PRE_HINTS%%

Write ONLY the summary, nothing else. No JSON, no bullet points — just natural language.]]

-- == v3 Scene Inventory prompt (pre-Pass 2) ====================================
-- Text-only call: clusters all photos into distinct visual scenes to give the
-- story assembly pass a birds-eye view of what's available. Prevents the AI
-- from creating redundant beats for similar content and ensures coverage of
-- distinct moments.
M.SCENE_INVENTORY_PROMPT_TEMPLATE = [[You are analyzing a photo collection to identify distinct MOMENTS.

## Collection Context
%%COLLECTION_CONTEXT%%

## Photo Collection (sorted chronologically)
%%PHOTO_LIST%%

## Task
Group these photos into DISTINCT MOMENTS — specific points in time when a particular group of people was doing a particular thing. Your goal is to help a story editor understand what unique moments exist so they can select one photo from each moment without redundancy.

## How to Identify Moments

### Step 1: Use CAPTURE TIME as the primary signal
Timestamps are the most reliable way to separate moments. Follow these rules strictly:
- Photos taken within ~2 minutes of each other with the same people = SAME moment (burst/posing variations)
- A gap of 10+ minutes almost always means a DIFFERENT moment, even if the subject looks similar
- A gap of 1+ hours is DEFINITELY a different moment
- For multi-day collections, any photos on different days are different moments regardless of similarity

### Step 2: Use PEOPLE as the secondary signal
Within the same time block, different combinations of people = different moments:
- Identify recurring people groups (e.g., "the couple", "the kids", "the whole family", "grandparents with grandkids")
- "Tom & Sarah alone" is a different moment than "Tom, Sarah & kids" even if taken 5 minutes apart at the same location
- Solo portraits are distinct from group shots at the same time/place

### Step 3: Use ACTIVITY as the tiebreaker
If time and people are the same, different activities distinguish moments:
- "Kids swimming" vs "Kids eating lunch" — same kids, but different activity
- "Family posing for photo" vs "Family playing game" — same group, but different activity

### What is the SAME moment (merge these):
- Burst shots of the same group in the same pose within seconds
- Multiple attempts at the same group photo taken back-to-back
- Slight reframings of the same scene taken seconds apart
- Photographer walking around the same scene (same people, same activity, within 1-2 minutes)

## People Groups
%%PEOPLE_GROUPS%%

## Output Format
For each moment, provide:
- scene_id: sequential number
- name: descriptive name including WHO and WHAT (e.g., "Tom & Sarah — couple portrait by lake", "Full group — arrival photo on dock")
- photo_numbers: array of photo numbers belonging to this moment
- count: how many photos in this moment
- best_composite: highest composite score among the photos
- time_range: approximate time range (e.g., "10:30-10:45" or "Day 3 afternoon")
- people: array of people names visible (if any)
- people_group: which recurring group this features (e.g., "the couple", "whole family", "kids only")
- categories: array of photo categories in this moment
- redundancy_note: if this moment could potentially be consolidated with another moment in a tight edit, note which and why (otherwise null). Use this ONLY for moments that serve a very similar narrative purpose — not just similar locations.

## Rules
- A moment should represent a SPECIFIC OCCURRENCE, not a category of activity.
- "Kids swimming" is too broad if it happened on 3 different days — those are 3 moments.
- Moments with only 1 photo are fine and common — a candid caught once is still a distinct moment.
- Order moments chronologically.
- The redundancy_note is for the story editor's benefit: "If space is tight, this moment serves a similar narrative role as Moment X." It does NOT mean they should be merged — both are real distinct moments.

Return ONLY valid JSON:
```json
{
  "scenes": [...],
  "total_scenes": 0,
  "people_groups_identified": ["the couple (Tom & Sarah)", "the kids (Emma, Jake)", "whole family"],
  "coverage_summary": "Brief note on what distinct moments this collection covers and the overall narrative arc",
  "redundancy_warnings": ["If space is tight: Moments X and Y serve similar narrative roles — the editor may want to pick one"]
}
```]]

-- == v3 Story Assembly prompt (Pass 2) ========================================
-- Text-only call: takes user story prompt + metadata rollup + snapshots → beat list.
-- This is the "spread all photos on the table" moment.
M.STORY_ASSEMBLY_PROMPT_TEMPLATE = [[You are an expert photo editor planning a curated photo story.

## The Photographer's Story
%%USER_STORY_PROMPT%%

%%EMPHASIS%%

## Event Timeline (from visual analysis of the photos)
%%EVENT_TIMELINE%%

## Collection Overview
%%METADATA_ROLLUP%%

## Moment Inventory (photos grouped into distinct moments)
%%SCENE_INVENTORY%%

## All Photos (text descriptions only — no images)
%%ALL_PHOTOS%%

## Task
Plan a photo story of exactly %%TARGET_COUNT%% beats (one photo per beat). Each beat represents a moment in the story. You are designing the story structure — later, a vision model will look at candidate photos to pick the best match for each beat.

CRITICAL: Use the Moment Inventory above to maximize coverage of distinct moments. Each beat should ideally draw from a DIFFERENT moment. Key rules:
- Prioritize BREADTH over DEPTH — one photo from each of 30 moments is better than 3 photos from 10 moments.
- Every moment in the inventory is a real, distinct occurrence (different people, time, or activity). Treat them as such even if the descriptions sound similar.
- If the target count is less than the number of moments, you must prioritize — favor moments that are narratively important, emotionally strong, or feature underrepresented people.
- If the target count exceeds the number of moments, you may draw multiple beats from the same moment, but prefer moments with high photo counts and score variety.
- Pay attention to redundancy_notes — when space is tight, they suggest which moments serve similar narrative roles so you can choose between them.

VISUAL DIVERSITY — the most common failure mode is creating beats that look the same:
- NEVER create two beats with the same visual content type. Two "person holding fish trophy" beats, two "rods bent at the stern" beats, or two "sunset landscape" beats will produce a repetitive story. Merge them into one beat or cut one.
- Each beat's description should produce a VISUALLY DISTINCT photo. Ask yourself: "Would a viewer flipping through these see variety, or repetition?"
- Unique moments (1-2 photos in the inventory) are precious — they are the only chance to show that content. Prioritize them over yet another variation of a common moment.
- Quiet, candid, or transitional moments (someone resting, cooking, laughing between action) are what give a story texture. Don't fill every slot with peak action.
- The story needs a genuine closing — end with an environmental or reflective beat, not an action peak.
- Unique subject matter (underwater, wildlife, aerial, macro) should be included even if image quality is lower — these are irreplaceable perspectives that add dimension to the story.

For each beat, specify:
- position: sequence number (1 to %%TARGET_COUNT%%)
- beat: short name for this story moment (e.g., "Opening — Group establishing shot")
- description: 1-2 sentences describing the ideal photo for this beat
- narrative_role: one of [establishing, scene_setter, character_moment, action, detail, transition, emotional_peak, closing]
- search_criteria: object with:
  - must_have: array of requirements (e.g., ["group shot", "all 4 people"])
  - prefer: array of preferences (e.g., ["morning light", "high emotion score"])
  - avoid: array of things to avoid (e.g., ["similar to beat 1"])
  - category_hint: array of preferred categories (e.g., ["portrait"])
  - time_range: string hint like "early in the day" or "after lunch" (or "any")
  - min_composite: minimum composite score threshold (number, e.g., 6.0)

Also include:
- category_targets: object mapping category names to target beat counts (e.g., {"portrait": "4-5 beats"})
- people_targets: object mapping people/groups to minimum representation (e.g., {"All 4 together": "at least 2 beats"})

## Constraints
- Plan EXACTLY %%TARGET_COUNT%% beats
- Distribute beats across the full timeline
- Ensure category variety (portraits, action, landscapes, details)
- Ensure people representation — every named person should appear in at least one beat
- The story should have a clear arc: opening → development → highlights → closing
- Reference the photographer's story and emphasis when prioritizing moments
- Use the event timeline to ground beats in what actually happened
- Set min_composite appropriately — hero shots should require higher scores, transitional shots can be lower
- NO TWO BEATS should produce visually similar photos — every beat must describe a different visual scene (different people, different activity, different setting)
- Include at least one quiet/candid/transitional moment (rest, food, travel, laughter between action) — these give the story texture and breathing room
- Unique 1-photo moments from the inventory deserve strong consideration — they cannot be represented any other way

Return ONLY valid JSON. No explanation, no markdown, no commentary.

```json
{
  "story_title": "...",
  "beats": [...],
  "category_targets": {...},
  "people_targets": {...}
}
```]]

-- == v3 Candidate Ranking prompt (Pass 3B) ====================================
-- Text-only call per beat: ranks pre-filtered candidates by semantic match.
M.CANDIDATE_RANKING_PROMPT_TEMPLATE = [[CANDIDATE RANKING

Beat %%BEAT_NUM%% of %%TOTAL_BEATS%%: "%%BEAT_DESCRIPTION%%"
Narrative role: %%NARRATIVE_ROLE%%
What to look for: %%SEARCH_CRITERIA%%

Here are %%NUM_CANDIDATES%% candidate photos (text descriptions only). Rank the top 8 that best match this beat's requirements. If fewer than 8 candidates, rank all of them.

CANDIDATES:
%%CANDIDATE_LIST%%

Return ONLY valid JSON:
{"ranked": [1, 15, 7, 23, 4, 12, 9, 31], "reasoning": "Brief explanation of top picks"}

The numbers in "ranked" are the candidate numbers listed above, in order from best match to worst. Return the NUMBERS, not photo IDs.]]


-- == Beat Casting prompt (Pass 4 — vision) ====================================
-- Per-beat vision call: AI sees candidate images and picks the best match.
M.BEAT_CASTING_PROMPT_TEMPLATE = [[You are selecting a photo for a specific moment in a story.

STORY CONTEXT:
"%%STORY_PROMPT%%"

THIS BEAT:
Position %%BEAT_NUM%% of %%TOTAL_BEATS%%: "%%BEAT_DESCRIPTION%%"
Narrative role: %%NARRATIVE_ROLE%%
What to look for: %%MUST_HAVE%%
Prefer: %%PREFER%%
Avoid: %%AVOID%%

%%PREVIOUS_SELECTIONS%%

You are viewing %%NUM_CANDIDATES%% candidate photos IN ORDER for this beat.
Select the ONE photo that best serves this beat.
Also select a BACKUP in case the primary has issues.

CRITICAL: Return the photo NUMBER (1-based position) as shown. The first photo you see is 1, the second is 2, etc.

Return ONLY valid JSON:
{
  "primary": 1,
  "backup": 3,
  "reasoning": "Brief explanation of why this photo best serves the beat",
  "flag": null
}

flag should be "duplicate_risk" if the primary looks too similar to a previous selection, "weak_match" if none of the candidates are great for this beat, or null if the match is good.]]


-- == Story Review prompt (Pass 5 — vision) ====================================
M.STORY_REVIEW_PROMPT_TEMPLATE = [[STORY REVIEW

You are reviewing a photo story edit. The photographer described this story as:
"%%STORY_PROMPT%%"

The story was planned with these beats:
%%BEAT_LIST%%

%%BATCH_CONTEXT%%

The photos below are shown IN STORY ORDER, corresponding to beats %%BEAT_RANGE%%.

For each photo, assess:
1. BEAT FIT: Does this photo deliver on what the beat asked for? (strong/adequate/weak)
2. TECHNICAL: Any quality issues visible at this size? (ok/concern: [what])

For the batch as a whole, assess:
3. DUPLICATES: Are any two photos too visually similar? List pairs.
4. GAPS: What's missing from the story? What moment or type of shot would improve it?
5. PACING: Are there too many similar shots in a row?
6. STORY COHERENCE: Does this sequence tell the story the photographer described? Rate 1-10.

Return ONLY valid JSON:
{
  "photo_assessments": [
    {"position": 1, "beat_fit": "strong", "technical": "ok", "notes": ""}
  ],
  "duplicates": [
    {"positions": [4, 6], "description": "Nearly identical trophy poses"}
  ],
  "gaps": [
    {"after_position": 7, "suggestion": "A scenic shot would break up the action"}
  ],
  "pacing_issues": [
    {"positions": [3, 4, 5], "issue": "Three consecutive action shots"}
  ],
  "story_coherence": 7,
  "story_coherence_notes": "Strong narrative but missing key moment",
  "swap_recommendations": [
    {
      "position": 6,
      "reason": "Too similar to position 4",
      "look_for": "A different moment from this part of the story"
    }
  ],
  "batch_summary": "Running summary of this batch for carry-forward"
}]]


-- == Swap Resolution prompt (Pass 6 — vision) =================================
M.SWAP_RESOLUTION_PROMPT_TEMPLATE = [[SWAP EVALUATION

Story context: "%%STORY_PROMPT%%"
Beat %%BEAT_NUM%%: "%%BEAT_DESCRIPTION%%"

The reviewer flagged this photo for replacement:
Reason: "%%SWAP_REASON%%"
Suggestion: "%%LOOK_FOR%%"

Photo 1 is the CURRENT selection.
Photos 2-%%NUM_REPLACEMENTS%% are REPLACEMENT CANDIDATES.

Should the current photo be replaced? If so, which replacement is best?

Return ONLY valid JSON:
{
  "action": "swap",
  "replacement": 3,
  "reasoning": "Photo 3 better serves the beat because..."
}

action: "keep" if the current photo is actually the best option, "swap" if replacing.
If action is "keep", omit "replacement".]]


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

-- Robust JSON extraction from AI responses that may be wrapped in markdown fences.
-- Uses string.find instead of pattern matching to handle large responses and
-- responses containing backticks in string values.
-- Returns (table, nil) on success or (nil, errorMsg) on failure.
function M.extractJSON(raw)
    if not raw or raw == "" then
        return nil, "Empty response"
    end

    -- Level 1: Direct JSON parse
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == "table" then
        return data, nil
    end

    -- Level 2: Strip markdown fences using string.find (not pattern match)
    -- Find opening fence: ```json or ```
    local fenceStart = raw:find("```json")
    local contentStart
    if fenceStart then
        contentStart = fenceStart + 7  -- skip ```json
    else
        fenceStart = raw:find("```")
        if fenceStart then
            contentStart = fenceStart + 3
        end
    end
    if contentStart then
        -- Find the LAST ``` in the string (closing fence)
        local lastFence = nil
        local searchFrom = contentStart
        while true do
            local pos = raw:find("```", searchFrom, true)  -- plain find
            if not pos then break end
            lastFence = pos
            searchFrom = pos + 3
        end
        if lastFence and lastFence > contentStart then
            local block = raw:sub(contentStart, lastFence - 1)
            ok, data = pcall(json.decode, M.trim(block))
            if ok and type(data) == "table" then
                return data, nil
            end
        end
    end

    -- Level 3: Find JSON object in surrounding text (first { to last })
    local objStart = raw:find("{")
    local objEnd = raw:reverse():find("}")
    if objStart and objEnd then
        objEnd = #raw - objEnd + 1
        local objStr = raw:sub(objStart, objEnd)
        ok, data = pcall(json.decode, objStr)
        if ok and type(data) == "table" then
            return data, nil
        end
    end

    -- Level 4: Find JSON array (first [ to last ])
    local arrStart = raw:find("%[")
    local arrEnd = raw:reverse():find("%]")
    if arrStart and arrEnd then
        arrEnd = #raw - arrEnd + 1
        local arrStr = raw:sub(arrStart, arrEnd)
        ok, data = pcall(json.decode, arrStr)
        if ok and type(data) == "table" then
            return data, nil
        end
    end

    return nil, "Could not parse JSON from response: " .. raw:sub(1, 200)
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

    -- narrative_role is NOT assigned during scoring (Pass 1).
    -- It will be assigned during story assembly (Pass 2) with full context.

    return {
        technical      = math.max(1, math.min(10, tonumber(data.technical) or 5)),
        composition    = math.max(1, math.min(10, tonumber(data.composition) or 5)),
        emotion        = math.max(1, math.min(10, tonumber(data.emotion) or 5)),
        moment         = math.max(1, math.min(10, tonumber(data.moment) or 5)),
        content        = tostring(data.content or "unknown"),
        category       = catVal,
        eye_quality    = eyeVal,
        reject         = (data.reject == true or data.reject == "true"),
    }
end

-- Parse a batch scoring response.
-- Expects JSON: { "scores": [...], "snapshot": {...} }
-- Returns (scoresArray, snapshot, nil) or (nil, nil, errorMsg).
-- Scores are returned IN ORDER — caller maps by position, not by ID.
function M.parseBatchResponse(raw, stopReason)
    if not raw or raw == "" then
        return nil, nil, "Empty response from model"
    end

    -- Check for truncation from the provider's stop reason
    local truncated = false
    if stopReason then
        local sr = stopReason:lower()
        if sr == "max_tokens" or sr == "length" or sr == "maxoutputtokens"
           or sr == "max_output_tokens" then
            truncated = true
        end
    end

    local data, extractErr = M.extractJSON(raw)
    if not data then
        -- If JSON parse failed, attempt partial recovery of individual score objects
        local partialScores = M.recoverPartialScores(raw)
        if partialScores and #partialScores > 0 then
            local warnMsg = string.format(
                "Response %s— recovered %d of partial scores from malformed JSON",
                truncated and "TRUNCATED (model hit output token limit) " or "",
                #partialScores)
            return partialScores, nil, warnMsg
        end

        local reason = truncated
            and "Response TRUNCATED — model hit output token limit. Try reducing batch size or switching providers."
            or ("Could not parse batch response as JSON: " .. (extractErr or raw:sub(1, 300)))
        return nil, nil, reason
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

    -- Warn if truncated even though we got some scores (snapshot may be missing)
    local warnMsg = nil
    if truncated then
        warnMsg = string.format(
            "Response truncated (model hit output token limit) — got %d scores but snapshot may be incomplete",
            #scores)
    end

    return scores, snapshot, warnMsg
end

-- == Partial score recovery ===================================================
-- When JSON is truncated mid-response, try to extract individual score objects.
-- Each score is a self-contained {...} block with "technical", "composition", etc.
function M.recoverPartialScores(raw)
    local scores = {}
    -- Find all complete JSON objects that look like score entries
    -- Pattern: { ... "technical" ... "content" ... }
    for obj in raw:gmatch('%b{}') do
        -- Check if this looks like a score object (has technical and content fields)
        if obj:find('"technical"') and obj:find('"content"') then
            local ok, data = pcall(json.decode, obj)
            if ok and type(data) == "table" and data.technical then
                scores[#scores + 1] = M.normalizeScores(data)
            end
        end
    end
    return scores
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

    -- Extract usage for cost tracking
    if decoded.usage then
        recordUsage("claude", claudeModel,
            decoded.usage.input_tokens, decoded.usage.output_tokens)
    end

    -- stop_reason: "end_turn", "max_tokens", "stop_sequence"
    local stopReason = decoded.stop_reason

    if decoded.content and type(decoded.content) == "table" then
        for _, block in ipairs(decoded.content) do
            if block.type == "text" and block.text then
                return block.text, nil, stopReason
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

    -- Extract usage for cost tracking
    if decoded.usage then
        recordUsage("openai", openaiModel,
            decoded.usage.prompt_tokens, decoded.usage.completion_tokens)
    end

    -- finish_reason: "stop", "length" (= max tokens hit)
    local stopReason = decoded.choices and decoded.choices[1]
        and decoded.choices[1].finish_reason

    if decoded.choices and decoded.choices[1] and decoded.choices[1].message then
        return decoded.choices[1].message.content, nil, stopReason
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

    -- Gemini 2.5 models use "thinking" by default, which consumes output tokens.
    -- Disable thinking for structured scoring to prevent response truncation.
    local isThinkingModel = geminiModel:find("2%.5") ~= nil
    local genConfig = {
        maxOutputTokens = maxTokens or 4096,
    }
    if isThinkingModel then
        genConfig.thinkingConfig = { thinkingBudget = 0 }
    end

    local encodeOk, body = pcall(json.encode, {
        contents = {{
            parts = parts,
        }},
        generationConfig = genConfig,
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

    -- Extract usage for cost tracking
    -- Gemini returns usageMetadata.promptTokenCount and .candidatesTokenCount
    if decoded.usageMetadata then
        recordUsage("gemini", geminiModel,
            decoded.usageMetadata.promptTokenCount,
            decoded.usageMetadata.candidatesTokenCount)
    end

    -- finishReason: "STOP", "MAX_TOKENS", "SAFETY"
    local stopReason = decoded.candidates and decoded.candidates[1]
        and decoded.candidates[1].finishReason

    if decoded.candidates and decoded.candidates[1]
       and decoded.candidates[1].content
       and decoded.candidates[1].content.parts then
        local parts = decoded.candidates[1].content.parts
        -- Gemini 2.5 models may include "thought" parts (thinking/reasoning).
        -- We need the LAST non-thought text part (the actual response).
        local lastText = nil
        for _, part in ipairs(parts) do
            if part.text and not part.thought then
                lastText = part.text
            end
        end
        if lastText then
            return lastText, nil, stopReason
        end
        -- Fallback: if all parts are thought parts, take the last text part anyway
        for _, part in ipairs(parts) do
            if part.text then
                lastText = part.text
            end
        end
        if lastText then
            return lastText, nil, stopReason
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

    -- Extract usage for cost tracking
    if decoded.usage then
        recordUsage("claude", claudeModel,
            decoded.usage.input_tokens, decoded.usage.output_tokens)
    end

    -- stop_reason: "end_turn", "max_tokens", "stop_sequence"
    local stopReason = decoded.stop_reason

    if decoded.content and type(decoded.content) == "table" then
        for _, block in ipairs(decoded.content) do
            if block.type == "text" and block.text then
                return block.text, nil, stopReason
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

    -- Extract usage for cost tracking
    if decoded.usage then
        recordUsage("openai", openaiModel,
            decoded.usage.prompt_tokens, decoded.usage.completion_tokens)
    end

    -- finish_reason: "stop", "length" (= max tokens hit)
    local stopReason = decoded.choices and decoded.choices[1]
        and decoded.choices[1].finish_reason

    if decoded.choices and decoded.choices[1] and decoded.choices[1].message then
        return decoded.choices[1].message.content, nil, stopReason
    end

    return nil, "Unexpected OpenAI response: " .. tostring(result):sub(1, 200)
end

function M.queryGeminiText(prompt, geminiModel, apiKey, timeoutSecs, maxTokens)
    local ts = tostring(math.floor(LrDate.currentTime() * 1000))

    -- Gemini 2.5 models use "thinking" by default, which consumes output tokens.
    -- Disable thinking for structured JSON responses to prevent truncation.
    local isThinkingModel = geminiModel:find("2%.5") ~= nil
    local genConfig = {
        maxOutputTokens = maxTokens or 8192,
    }
    if isThinkingModel then
        genConfig.thinkingConfig = { thinkingBudget = 0 }
    end

    local encodeOk, body = pcall(json.encode, {
        contents = {{
            parts = {
                { text = prompt },
            },
        }},
        generationConfig = genConfig,
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

    -- Extract usage for cost tracking
    if decoded.usageMetadata then
        recordUsage("gemini", geminiModel,
            decoded.usageMetadata.promptTokenCount,
            decoded.usageMetadata.candidatesTokenCount)
    end

    -- finishReason: "STOP", "MAX_TOKENS", "SAFETY"
    local stopReason = decoded.candidates and decoded.candidates[1]
        and decoded.candidates[1].finishReason

    if decoded.candidates and decoded.candidates[1]
       and decoded.candidates[1].content
       and decoded.candidates[1].content.parts then
        -- Gemini 2.5 models may include "thought" parts (thinking/reasoning).
        -- We need the LAST non-thought text part (the actual response).
        local lastText = nil
        for _, part in ipairs(decoded.candidates[1].content.parts) do
            if part.text and not part.thought then
                lastText = part.text
            end
        end
        if lastText then
            return lastText, nil, stopReason
        end
        -- Fallback: if all parts are thought parts, take the last text part anyway
        for _, part in ipairs(decoded.candidates[1].content.parts) do
            if part.text then
                lastText = part.text
            end
        end
        if lastText then
            return lastText, nil, stopReason
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

-- == Parse story/synthesis response ===========================================
-- Expects a JSON array of { id, position, beat, role, note, alternates }.
-- Validates all IDs exist in the valid set and positions are sequential.
-- Returns (selectionArray, nil) or (nil, errorMsg).
function M.parseStoryResponse(raw, validIds)
    if not raw or raw == "" then
        return nil, "Empty response from model"
    end

    local data, extractErr = M.extractJSON(raw)
    if not data then
        return nil, "Could not parse story response as JSON: " .. (extractErr or raw:sub(1, 300))
    end

    -- Could be the array directly, or wrapped in an object
    if not (#data > 0 and data[1] and data[1].id) then
        if data.selections and type(data.selections) == "table" then
            data = data.selections
        elseif data.photos and type(data.photos) == "table" then
            data = data.photos
        elseif data.results and type(data.results) == "table" then
            data = data.results
        end
    end

    if type(data) ~= "table" or #data == 0 then
        return nil, "No selections array in story response: " .. raw:sub(1, 300)
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

-- == v3 Story prepopulation builder ============================================
-- Builds a prepopulation prompt from snapshots + metadata, makes a text-only
-- AI call, returns a natural language summary for the user to edit.
-- @param snapshots   Array of snapshot tables from Pass 1
-- @param photoStore  Table of photoStore entries (indexed by localIdentifier)
-- @param preHints    String: user's pre-hints from run dialog
-- @param prefs       Settings table for AI call
-- @return (summary, nil) or (nil, errorMsg)
function M.buildPrepopulationSummary(snapshots, photoStore, preHints, prefs)
    -- Build snapshot summaries
    local snapshotParts = {}
    if snapshots and #snapshots > 0 then
        for _, snap in ipairs(snapshots) do
            local line = string.format("Batch %d", snap.batchIndex or 0)
            if snap.timeRange then
                local tr = snap.timeRange
                if tr.start then line = line .. " (" .. tr.start end
                if tr.finish then line = line .. " to " .. tr.finish .. ")" end
            end
            line = line .. ": "
            local details = {}
            if snap.scene and snap.scene ~= "" then details[#details + 1] = "Scene: " .. snap.scene end
            if snap.people and type(snap.people) == "table" and #snap.people > 0 then
                details[#details + 1] = "People: " .. table.concat(snap.people, ", ")
            end
            if snap.mood and snap.mood ~= "" then details[#details + 1] = "Mood: " .. snap.mood end
            if snap.setting and snap.setting ~= "" then details[#details + 1] = "Setting: " .. snap.setting end
            if snap.action and snap.action ~= "" then details[#details + 1] = "Action: " .. snap.action end
            line = line .. table.concat(details, ". ")
            snapshotParts[#snapshotParts + 1] = line
        end
    else
        snapshotParts[#snapshotParts + 1] = "(No visual snapshots available)"
    end

    -- Build category counts and people counts from photoStore
    local categoryCounts = {}
    local peopleCounts = {}
    local totalPhotos = 0
    local minTime, maxTime

    for _, store in pairs(photoStore) do
        totalPhotos = totalPhotos + 1
        categoryCounts[store.category] = (categoryCounts[store.category] or 0) + 1
        if store.people then
            for _, name in ipairs(store.people) do
                peopleCounts[name] = (peopleCounts[name] or 0) + 1
            end
        end
        if store.captureTime then
            if not minTime or store.captureTime < minTime then minTime = store.captureTime end
            if not maxTime or store.captureTime > maxTime then maxTime = store.captureTime end
        end
    end

    -- Format category summary
    local catParts = {}
    for cat, count in pairs(categoryCounts) do
        catParts[#catParts + 1] = string.format("%s: %d", cat, count)
    end
    local categorySummary = #catParts > 0 and table.concat(catParts, ", ") or "Unknown"

    -- Format people summary
    local peopleParts = {}
    for name, count in pairs(peopleCounts) do
        peopleParts[#peopleParts + 1] = string.format("%s (%d photos)", name, count)
    end
    local peopleSummary = #peopleParts > 0 and table.concat(peopleParts, ", ") or "No named people detected"

    -- Format time range
    local timeRange = "Unknown"
    if minTime and maxTime then
        local minStr = LrDate.timeToUserFormat(minTime, "%Y-%m-%d %H:%M")
        local maxStr = LrDate.timeToUserFormat(maxTime, "%Y-%m-%d %H:%M")
        if minStr == maxStr then
            timeRange = minStr
        else
            timeRange = minStr .. " to " .. maxStr
        end
    end

    -- Build the prompt
    local prompt = M.PREPOPULATE_PROMPT_TEMPLATE
    prompt = prompt:gsub("%%%%SNAPSHOT_SUMMARIES%%%%", function() return table.concat(snapshotParts, "\n") end)
    prompt = prompt:gsub("%%%%PEOPLE_SUMMARY%%%%", function() return peopleSummary end)
    prompt = prompt:gsub("%%%%CATEGORY_SUMMARY%%%%", function() return categorySummary end)
    prompt = prompt:gsub("%%%%TIME_RANGE%%%%", function() return timeRange end)
    prompt = prompt:gsub("%%%%TOTAL_PHOTOS%%%%", function() return tostring(totalPhotos) end)

    local hintsText = ""
    if preHints and preHints ~= "" then
        hintsText = "Photographer's notes: " .. preHints
    end
    prompt = prompt:gsub("%%%%PRE_HINTS%%%%", function() return hintsText end)

    -- Make the text-only AI call
    local maxTokens = 512  -- short response
    local response, err = M.queryText(prompt, prefs, maxTokens)
    if not response then
        return nil, err
    end

    -- Clean up response — remove any quotes, markdown, etc.
    response = response:gsub("^%s+", ""):gsub("%s+$", "")
    response = response:gsub('^"', ""):gsub('"$', "")

    return response, nil
end

-- Fallback prepopulation when AI call fails.
-- Returns a template-based summary from available data.
function M.buildPrepopulationFallback(snapshots, photoStore, preHints)
    local totalPhotos = 0
    local categoryCounts = {}
    local peopleCounts = {}
    local minTime, maxTime

    for _, store in pairs(photoStore) do
        totalPhotos = totalPhotos + 1
        categoryCounts[store.category] = (categoryCounts[store.category] or 0) + 1
        if store.people then
            for _, name in ipairs(store.people) do
                peopleCounts[name] = (peopleCounts[name] or 0) + 1
            end
        end
        if store.captureTime then
            if not minTime or store.captureTime < minTime then minTime = store.captureTime end
            if not maxTime or store.captureTime > maxTime then maxTime = store.captureTime end
        end
    end

    local parts = {}
    parts[#parts + 1] = string.format("%d photos", totalPhotos)

    if minTime and maxTime then
        local minStr = LrDate.timeToUserFormat(minTime, "%Y-%m-%d %H:%M")
        local maxStr = LrDate.timeToUserFormat(maxTime, "%Y-%m-%d %H:%M")
        parts[#parts + 1] = string.format("from %s to %s", minStr, maxStr)
    end

    local nameList = {}
    for name, _ in pairs(peopleCounts) do nameList[#nameList + 1] = name end
    if #nameList > 0 then
        parts[#parts + 1] = string.format("%d people identified: %s", #nameList, table.concat(nameList, ", "))
    end

    local catParts = {}
    for cat, count in pairs(categoryCounts) do
        catParts[#catParts + 1] = string.format("%s (%d)", cat, count)
    end
    if #catParts > 0 then
        parts[#parts + 1] = "Categories: " .. table.concat(catParts, ", ")
    end

    -- Add snapshot scenes
    if snapshots and #snapshots > 0 then
        local scenes = {}
        for _, snap in ipairs(snapshots) do
            if snap.scene and snap.scene ~= "" then
                scenes[#scenes + 1] = snap.scene
            end
        end
        if #scenes > 0 then
            parts[#parts + 1] = "Key scenes: " .. table.concat(scenes, "; "):sub(1, 200)
        end
    end

    return table.concat(parts, ". ") .. "."
end

-- == v3 Story assembly: build metadata rollup =================================
-- Aggregates scored photo data into a rollup for the story assembly prompt.
-- @param photoStore  Table indexed by localIdentifier
-- @return rollup table
function M.buildMetadataRollup(photoStore)
    local totalPhotos = 0
    local categoryCounts = {}
    local peopleCounts = {}
    local soloCount = {}
    local composites = {}
    local minTime, maxTime

    for _, store in pairs(photoStore) do repeat
        if store.reject then break end
        totalPhotos = totalPhotos + 1
        categoryCounts[store.category] = (categoryCounts[store.category] or 0) + 1
        composites[#composites + 1] = store.composite

        local personCount = 0
        if store.people then
            for _, name in ipairs(store.people) do
                peopleCounts[name] = (peopleCounts[name] or 0) + 1
                personCount = personCount + 1
            end
            -- Track solo shots (exactly 1 person)
            if personCount == 1 then
                local soloName = store.people[1]
                soloCount[soloName] = (soloCount[soloName] or 0) + 1
            end
        end

        if store.captureTime then
            if not minTime or store.captureTime < minTime then minTime = store.captureTime end
            if not maxTime or store.captureTime > maxTime then maxTime = store.captureTime end
        end
    until true end

    -- Score distribution stats
    table.sort(composites)
    local compositeMin = composites[1] or 0
    local compositeMax = composites[#composites] or 0
    local compositeMean = 0
    for _, c in ipairs(composites) do compositeMean = compositeMean + c end
    if #composites > 0 then compositeMean = compositeMean / #composites end

    local topQuartileIdx = math.max(1, math.floor(#composites * 0.75))
    local topQuartileThreshold = composites[topQuartileIdx] or 0

    -- Group shots count
    local groupShots = 0
    for _, store in pairs(photoStore) do
        if store.people and #store.people >= 3 then
            groupShots = groupShots + 1
        end
    end

    -- Build people table
    local people = {}
    for name, count in pairs(peopleCounts) do
        people[name] = {
            count = count,
            soloCount = soloCount[name] or 0,
        }
    end

    -- Time range
    local timeRange = ""
    if minTime and maxTime then
        timeRange = LrDate.timeToUserFormat(minTime, "%Y-%m-%d %H:%M") .. " to " ..
                    LrDate.timeToUserFormat(maxTime, "%Y-%m-%d %H:%M")
    end

    return {
        totalPhotos = totalPhotos,
        categoryBreakdown = categoryCounts,
        scoreDistribution = {
            compositeRange = { compositeMin, compositeMax },
            compositeMean = math.floor(compositeMean * 10 + 0.5) / 10,
            topQuartileThreshold = math.floor(topQuartileThreshold * 10 + 0.5) / 10,
        },
        people = people,
        groupShots = groupShots,
        timeRange = timeRange,
        _minTime = minTime,   -- raw timestamps for duration calculation
        _maxTime = maxTime,
    }
end

-- == v3 Scene Inventory prompt builder =========================================
-- Builds the scene inventory prompt from the photo list text + collection context.
-- @param allPhotosText  String: formatted text of all photo metadata (same as Pass 2)
-- @param rollup         Table: from buildMetadataRollup (has timeRange, people, etc.)
-- @return string: the complete prompt
function M.buildSceneInventoryPrompt(allPhotosText, rollup)
    local prompt = M.SCENE_INVENTORY_PROMPT_TEMPLATE

    -- Build collection context: trip duration, total photos, time span
    local contextParts = {}
    contextParts[#contextParts + 1] = string.format("Total photos: %d", rollup.totalPhotos or 0)
    if rollup.timeRange and rollup.timeRange ~= "" then
        contextParts[#contextParts + 1] = "Time span: " .. rollup.timeRange
    end
    -- Calculate duration in human terms
    if rollup._minTime and rollup._maxTime then
        local durationSecs = rollup._maxTime - rollup._minTime
        local durationMins = math.floor(durationSecs / 60)
        local durationHours = math.floor(durationMins / 60)
        local durationDays = math.floor(durationHours / 24)
        local durationMonths = math.floor(durationDays / 30)
        local durationYears = math.floor(durationDays / 365)
        if durationYears >= 1 then
            contextParts[#contextParts + 1] = string.format(
                "Duration: ~%d year(s) — this is a COMPILATION spanning a long period. "
                .. "Photos are NOT from a single trip or event. Each shooting session or date "
                .. "is its own independent context. Time gaps between sessions can be weeks or months.",
                durationYears)
        elseif durationMonths >= 1 then
            contextParts[#contextParts + 1] = string.format(
                "Duration: ~%d month(s) — this collection spans multiple weeks. "
                .. "Look for clusters of photos on specific dates as distinct shooting sessions. "
                .. "Photos on different dates are always different moments.",
                durationMonths)
        elseif durationDays > 1 then
            contextParts[#contextParts + 1] = string.format(
                "Duration: %d days — this is a MULTI-DAY collection (e.g., a trip or event). "
                .. "Photos on different days are always different moments, even if the subject is similar.",
                durationDays)
        elseif durationHours > 2 then
            contextParts[#contextParts + 1] = string.format(
                "Duration: ~%d hours — this is a long session spanning most of a day.",
                durationHours)
        elseif durationMins > 30 then
            contextParts[#contextParts + 1] = string.format(
                "Duration: ~%d minutes — this is a single session.",
                durationMins)
        else
            contextParts[#contextParts + 1] = string.format(
                "Duration: ~%d minutes — this is a short, focused session.",
                durationMins)
        end
    end
    local collectionContext = table.concat(contextParts, "\n")

    -- Build people groups section from rollup
    local peopleLines = {}
    if rollup.people and next(rollup.people) then
        peopleLines[#peopleLines + 1] = "Named people in this collection:"
        -- Sort by frequency
        local sortedPeople = {}
        for name, info in pairs(rollup.people) do
            sortedPeople[#sortedPeople + 1] = { name = name, count = info.count, solo = info.soloCount }
        end
        table.sort(sortedPeople, function(a, b) return a.count > b.count end)
        for _, p in ipairs(sortedPeople) do
            peopleLines[#peopleLines + 1] = string.format(
                "- %s: appears in %d photos (%d solo shots)",
                p.name, p.count, p.solo)
        end
        if rollup.groupShots and rollup.groupShots > 0 then
            peopleLines[#peopleLines + 1] = string.format(
                "\nGroup shots (3+ people): %d photos", rollup.groupShots)
        end
        peopleLines[#peopleLines + 1] = "\nLook for recurring combinations of these people to identify people groups (e.g., \"the couple\", \"the kids\", \"whole family\")."
    else
        peopleLines[#peopleLines + 1] = "No named people detected in this collection."
    end
    local peopleGroupsText = table.concat(peopleLines, "\n")

    prompt = prompt:gsub("%%%%COLLECTION_CONTEXT%%%%", function() return collectionContext end)
    prompt = prompt:gsub("%%%%PHOTO_LIST%%%%", function() return allPhotosText end)
    prompt = prompt:gsub("%%%%PEOPLE_GROUPS%%%%", function() return peopleGroupsText end)
    return prompt
end

-- == v3 Scene Inventory response parser =======================================
-- @param raw  String: raw AI response
-- @return (inventoryTable, nil) or (nil, errorMsg)
function M.parseSceneInventoryResponse(raw)
    local data, extractErr = M.extractJSON(raw)
    if not data then
        return nil, "Could not parse scene inventory JSON: " .. (extractErr or "")
    end

    -- Validate scenes array exists
    local scenes = data.scenes
    if not scenes or type(scenes) ~= "table" or #scenes == 0 then
        return nil, "Scene inventory has no scenes"
    end

    return data, nil
end

-- == v3 Format scene inventory for injection into Pass 2 prompt ===============
-- Converts the parsed scene inventory into readable text for the story assembly.
-- @param inventory  Table: parsed scene inventory (from parseSceneInventoryResponse)
-- @return string: formatted text
function M.formatSceneInventory(inventory)
    local lines = {}

    lines[#lines + 1] = string.format("Total distinct moments: %d",
        inventory.total_scenes or #inventory.scenes)

    if inventory.people_groups_identified and #inventory.people_groups_identified > 0 then
        lines[#lines + 1] = "People groups: " .. table.concat(inventory.people_groups_identified, ", ")
    end
    if inventory.coverage_summary then
        lines[#lines + 1] = "Coverage: " .. inventory.coverage_summary
    end

    lines[#lines + 1] = ""

    for _, scene in ipairs(inventory.scenes) do
        local header = string.format("Moment %d: %s (%d photos, best=%.1f, time=%s)",
            scene.scene_id or 0,
            scene.name or "unnamed",
            scene.count or #(scene.photo_numbers or {}),
            scene.best_composite or 0,
            scene.time_range or "unknown")
        lines[#lines + 1] = header

        if scene.people_group then
            lines[#lines + 1] = "  Group: " .. scene.people_group
        end
        if scene.people and #scene.people > 0 then
            lines[#lines + 1] = "  People: " .. table.concat(scene.people, ", ")
        end
        if scene.categories and #scene.categories > 0 then
            lines[#lines + 1] = "  Categories: " .. table.concat(scene.categories, ", ")
        end
        if scene.photo_numbers and #scene.photo_numbers > 0 then
            local nums = {}
            for _, n in ipairs(scene.photo_numbers) do nums[#nums + 1] = tostring(n) end
            lines[#lines + 1] = "  Photos: " .. table.concat(nums, ", ")
        end
        if scene.redundancy_note then
            lines[#lines + 1] = "  ⚠ Similar narrative role: " .. scene.redundancy_note
        end
        lines[#lines + 1] = ""
    end

    if inventory.redundancy_warnings and #inventory.redundancy_warnings > 0 then
        lines[#lines + 1] = "NARRATIVE OVERLAP NOTES:"
        for _, w in ipairs(inventory.redundancy_warnings) do
            lines[#lines + 1] = "  - " .. w
        end
    end

    return table.concat(lines, "\n")
end

-- == v3 Story assembly prompt builder ==========================================
-- Builds the complete Pass 2 prompt from user story + rollup + snapshots + photos.
-- @param userStoryPrompt  String: confirmed user story description
-- @param emphasis         String: optional emphasis ("the dive was the highlight")
-- @param eventTimeline    String: merged snapshot text (event blocks)
-- @param rollup           Table: from buildMetadataRollup
-- @param allPhotosText    String: formatted text of all photo metadata
-- @param targetCount      Number: number of beats to plan
-- @param sceneInventory   String: formatted scene inventory (from formatSceneInventory), or nil
-- @return string: the complete prompt
function M.buildStoryAssemblyPrompt(userStoryPrompt, emphasis, eventTimeline, rollup, allPhotosText, targetCount, sceneInventory)
    local prompt = M.STORY_ASSEMBLY_PROMPT_TEMPLATE

    local emphasisText = ""
    if emphasis and emphasis ~= "" then
        emphasisText = "## Emphasis\nThe photographer specifically asked to emphasize: " .. emphasis
    end

    local sceneText = sceneInventory or "[Scene inventory not available — use photo descriptions to identify distinct moments.]"

    local rollupJson = json.encode(rollup)

    prompt = prompt:gsub("%%%%USER_STORY_PROMPT%%%%", function() return userStoryPrompt end)
    prompt = prompt:gsub("%%%%EMPHASIS%%%%", function() return emphasisText end)
    prompt = prompt:gsub("%%%%EVENT_TIMELINE%%%%", function() return eventTimeline end)
    prompt = prompt:gsub("%%%%METADATA_ROLLUP%%%%", function() return rollupJson end)
    prompt = prompt:gsub("%%%%SCENE_INVENTORY%%%%", function() return sceneText end)
    prompt = prompt:gsub("%%%%ALL_PHOTOS%%%%", function() return allPhotosText end)
    prompt = prompt:gsub("%%%%TARGET_COUNT%%%%", function() return tostring(targetCount) end)

    return prompt
end

-- == v3 Beat list parser ======================================================
-- Parses the story assembly response into a structured beat list.
-- @param raw  String: raw AI response
-- @return (beatList, nil) or (nil, errorMsg)
function M.parseBeatListResponse(raw)
    local data, extractErr = M.extractJSON(raw)
    if not data then
        return nil, "Could not parse beat list response as JSON: " .. (extractErr or raw:sub(1, 300))
    end

    -- Extract beats array
    local beatsRaw = data.beats
    if not beatsRaw or type(beatsRaw) ~= "table" or #beatsRaw == 0 then
        return nil, "No beats array in story assembly response: " .. raw:sub(1, 300)
    end

    -- Normalize beats
    local beats = {}
    for _, b in ipairs(beatsRaw) do
        local searchCriteria = b.search_criteria or {}
        beats[#beats + 1] = {
            position       = tonumber(b.position) or (#beats + 1),
            beat           = tostring(b.beat or ""),
            description    = tostring(b.description or ""),
            narrativeRole  = tostring(b.narrative_role or "detail"),
            searchCriteria = {
                mustHave     = searchCriteria.must_have or {},
                prefer       = searchCriteria.prefer or {},
                avoid        = searchCriteria.avoid or {},
                categoryHint = searchCriteria.category_hint or {},
                timeRange    = tostring(searchCriteria.time_range or "any"),
                minComposite = tonumber(searchCriteria.min_composite) or 5.0,
            },
        }
    end

    -- Sort by position
    table.sort(beats, function(a, b) return a.position < b.position end)

    -- Re-number positions sequentially
    for i, beat in ipairs(beats) do
        beat.position = i
    end

    return {
        storyTitle      = data.story_title or "Untitled Story",
        beats           = beats,
        categoryTargets = data.category_targets or {},
        peopleTargets   = data.people_targets or {},
    }, nil
end

-- == v3 Candidate ranking prompt builder ======================================
-- Builds the text-only ranking prompt for Pass 3B.
-- @param beatNum          Number: current beat position
-- @param totalBeats       Number: total beats in story
-- @param beatDescription  String: beat description
-- @param narrativeRole    String: beat narrative role
-- @param searchCriteria   Table: beat search criteria
-- @param candidates       Array of {num, content, composite, category, people, time}
-- @return string: the prompt
function M.buildCandidateRankingPrompt(beatNum, totalBeats, beatDescription, narrativeRole, searchCriteria, candidates)
    local prompt = M.CANDIDATE_RANKING_PROMPT_TEMPLATE

    -- Format search criteria as readable text
    local criteriaParts = {}
    if searchCriteria.mustHave and #searchCriteria.mustHave > 0 then
        criteriaParts[#criteriaParts + 1] = "Must have: " .. table.concat(searchCriteria.mustHave, ", ")
    end
    if searchCriteria.prefer and #searchCriteria.prefer > 0 then
        criteriaParts[#criteriaParts + 1] = "Prefer: " .. table.concat(searchCriteria.prefer, ", ")
    end
    if searchCriteria.avoid and #searchCriteria.avoid > 0 then
        criteriaParts[#criteriaParts + 1] = "Avoid: " .. table.concat(searchCriteria.avoid, ", ")
    end
    local criteriaText = table.concat(criteriaParts, ". ")

    -- Format candidate list
    local candidateLines = {}
    for _, c in ipairs(candidates) do
        local peopleTxt = ""
        if c.people and #c.people > 0 then
            peopleTxt = ", people=[" .. table.concat(c.people, ",") .. "]"
        end
        candidateLines[#candidateLines + 1] = string.format(
            '%d. (composite=%.1f, category=%s%s, time=%s)\n   "%s"',
            c.num, c.composite or 0, c.category or "other", peopleTxt,
            c.time or "unknown", c.content or "unknown"
        )
    end

    prompt = prompt:gsub("%%%%BEAT_NUM%%%%", function() return tostring(beatNum) end)
    prompt = prompt:gsub("%%%%TOTAL_BEATS%%%%", function() return tostring(totalBeats) end)
    prompt = prompt:gsub("%%%%BEAT_DESCRIPTION%%%%", function() return beatDescription end)
    prompt = prompt:gsub("%%%%NARRATIVE_ROLE%%%%", function() return narrativeRole end)
    prompt = prompt:gsub("%%%%SEARCH_CRITERIA%%%%", function() return criteriaText end)
    prompt = prompt:gsub("%%%%NUM_CANDIDATES%%%%", function() return tostring(#candidates) end)
    prompt = prompt:gsub("%%%%CANDIDATE_LIST%%%%", function() return table.concat(candidateLines, "\n") end)

    return prompt
end

-- == v3 Parse candidate ranking response ======================================
function M.parseCandidateRankingResponse(raw)
    local data, extractErr = M.extractJSON(raw)

    if not data then
        return nil, "Could not extract JSON from ranking response: " .. (extractErr or "unknown")
    end

    -- Try multiple key names (LLM frequently paraphrases)
    local rankedArr = data.ranked or data.ranking or data.rankings
        or data.top_candidates or data.candidates or data.order
        or data.top or data.results

    -- Handle bare array response: data itself is [1, 5, 3, ...]
    if not rankedArr and type(data) == "table" and type(data[1]) == "number" then
        rankedArr = data
    end

    if rankedArr and type(rankedArr) == "table" then
        -- Validate all entries are numbers
        local ranked = {}
        for _, v in ipairs(rankedArr) do
            local n = tonumber(v)
            if n then ranked[#ranked + 1] = n end
        end
        if #ranked > 0 then
            return ranked, nil
        end
    end

    return nil, "Could not parse candidate ranking: " .. (raw or ""):sub(1, 200)
end

-- == v3 Build beat casting prompt (Pass 4) ====================================
-- Builds a vision prompt for selecting the best candidate image for a beat.
-- @param storyPrompt     User's confirmed story description
-- @param beatNum         Position number of this beat
-- @param totalBeats      Total number of beats in the story
-- @param beatDescription Description of what this beat should capture
-- @param narrativeRole   The narrative role (establishing, scene_setter, etc.)
-- @param searchCriteria  Table with mustHave, prefer, avoid arrays
-- @param numCandidates   Number of candidate images being sent
-- @param previousSelections Array of {content=..., beat=...} for prior picks
-- @return prompt string
function M.buildBeatCastingPrompt(storyPrompt, beatNum, totalBeats, beatDescription,
                                   narrativeRole, searchCriteria, numCandidates, previousSelections)
    local prompt = M.BEAT_CASTING_PROMPT_TEMPLATE

    -- Format search criteria fields
    local mustHave = "none specified"
    local prefer   = "none specified"
    local avoid    = "none specified"
    if searchCriteria then
        if searchCriteria.mustHave and #searchCriteria.mustHave > 0 then
            mustHave = table.concat(searchCriteria.mustHave, ", ")
        end
        if searchCriteria.prefer and #searchCriteria.prefer > 0 then
            prefer = table.concat(searchCriteria.prefer, ", ")
        end
        if searchCriteria.avoid and #searchCriteria.avoid > 0 then
            avoid = table.concat(searchCriteria.avoid, ", ")
        end
    end

    -- Format previous selections context
    local prevText = ""
    if previousSelections and #previousSelections > 0 then
        local lines = { "PREVIOUS SELECTIONS (for context — avoid redundancy):" }
        for _, sel in ipairs(previousSelections) do
            lines[#lines + 1] = string.format('  Beat %d: "%s"',
                sel.position or 0, (sel.content or ""):sub(1, 80))
        end
        prevText = table.concat(lines, "\n")
    else
        prevText = "This is the first beat — no previous selections yet."
    end

    prompt = prompt:gsub("%%%%STORY_PROMPT%%%%", function() return storyPrompt end)
    prompt = prompt:gsub("%%%%BEAT_NUM%%%%", function() return tostring(beatNum) end)
    prompt = prompt:gsub("%%%%TOTAL_BEATS%%%%", function() return tostring(totalBeats) end)
    prompt = prompt:gsub("%%%%BEAT_DESCRIPTION%%%%", function() return beatDescription end)
    prompt = prompt:gsub("%%%%NARRATIVE_ROLE%%%%", function() return narrativeRole or "general" end)
    prompt = prompt:gsub("%%%%MUST_HAVE%%%%", function() return mustHave end)
    prompt = prompt:gsub("%%%%PREFER%%%%", function() return prefer end)
    prompt = prompt:gsub("%%%%AVOID%%%%", function() return avoid end)
    prompt = prompt:gsub("%%%%PREVIOUS_SELECTIONS%%%%", function() return prevText end)
    prompt = prompt:gsub("%%%%NUM_CANDIDATES%%%%", function() return tostring(numCandidates) end)

    return prompt
end

-- == v3 Parse beat casting response ===========================================
-- Parses the vision model's response to a beat casting call.
-- @return table {primary, backup, reasoning, flag} or nil, error
function M.parseBeatCastingResponse(raw)
    local data, extractErr = M.extractJSON(raw)

    if data and data.primary then
        return {
            primary   = tonumber(data.primary),
            backup    = tonumber(data.backup),
            reasoning = data.reasoning or "",
            flag      = data.flag,     -- nil, "duplicate_risk", or "weak_match"
        }, nil
    end

    return nil, "Could not parse beat casting: " .. (raw or ""):sub(1, 200)
end

-- == v3 Build story review prompt (Pass 5) ====================================
function M.buildStoryReviewPrompt(storyPrompt, beats, beatRange, batchContext)
    local prompt = M.STORY_REVIEW_PROMPT_TEMPLATE

    -- Format beat list
    local beatLines = {}
    for _, beat in ipairs(beats) do
        beatLines[#beatLines + 1] = string.format('%d. %s — role: %s',
            beat.position or 0, beat.beat or beat.description or "beat",
            beat.narrativeRole or "general")
    end
    local beatListText = table.concat(beatLines, "\n")

    -- Batch context (for multi-batch reviews)
    local contextText = ""
    if batchContext and batchContext ~= "" then
        contextText = "Previous batch summary:\n" .. batchContext
    end

    prompt = prompt:gsub("%%%%STORY_PROMPT%%%%", function() return storyPrompt end)
    prompt = prompt:gsub("%%%%BEAT_LIST%%%%", function() return beatListText end)
    prompt = prompt:gsub("%%%%BEAT_RANGE%%%%", function() return beatRange or "all" end)
    prompt = prompt:gsub("%%%%BATCH_CONTEXT%%%%", function() return contextText end)

    return prompt
end

-- == v3 Parse story review response ===========================================
function M.parseStoryReviewResponse(raw)
    local data, err = M.extractJSON(raw)
    if not data then
        return nil, "Could not parse story review: " .. (err or (raw or ""):sub(1, 200))
    end

    return {
        photoAssessments   = data.photo_assessments or {},
        duplicates         = data.duplicates or {},
        gaps               = data.gaps or {},
        pacingIssues       = data.pacing_issues or {},
        storyCoherence     = tonumber(data.story_coherence) or 5,
        coherenceNotes     = data.story_coherence_notes or "",
        swapRecommendations = data.swap_recommendations or {},
        batchSummary       = data.batch_summary or "",
    }, nil
end

-- == v3 Build swap resolution prompt (Pass 6) =================================
function M.buildSwapResolutionPrompt(storyPrompt, beatNum, beatDescription,
                                      swapReason, lookFor, numReplacements)
    local prompt = M.SWAP_RESOLUTION_PROMPT_TEMPLATE

    prompt = prompt:gsub("%%%%STORY_PROMPT%%%%", function() return storyPrompt end)
    prompt = prompt:gsub("%%%%BEAT_NUM%%%%", function() return tostring(beatNum) end)
    prompt = prompt:gsub("%%%%BEAT_DESCRIPTION%%%%", function() return beatDescription end)
    prompt = prompt:gsub("%%%%SWAP_REASON%%%%", function() return swapReason or "" end)
    prompt = prompt:gsub("%%%%LOOK_FOR%%%%", function() return lookFor or "" end)
    prompt = prompt:gsub("%%%%NUM_REPLACEMENTS%%%%", function() return tostring(numReplacements + 1) end)  -- +1 for current

    return prompt
end

-- == v3 Parse swap resolution response ========================================
function M.parseSwapResolutionResponse(raw)
    local data, extractErr = M.extractJSON(raw)

    if data and data.action then
        return {
            action      = data.action,       -- "keep" or "swap"
            replacement = tonumber(data.replacement),
            reasoning   = data.reasoning or "",
        }, nil
    end

    return nil, "Could not parse swap resolution: " .. (raw or ""):sub(1, 200)
end

-- == v3 Unified vision query (images + prompt, no anchors) ====================
-- Simplified wrapper around queryBatch for Passes 4, 5, 6.
-- @param images  Array of {base64, fileSize} for candidate photos
-- @param labels  Array of label strings (e.g., "[Photo 1]", "[Photo 2]")
-- @param prompt  The prompt text
-- @param prefs   Preferences table (provider, model, apiKey, etc.)
-- @param maxTokens Max output tokens (default 1024)
-- @return (rawText, nil) or (nil, errorMsg)
function M.queryVision(images, labels, prompt, prefs, maxTokens)
    return M.queryBatch(images, labels, nil, nil, prompt, prefs, maxTokens or 1024)
end


-- == Perceptual hashing (dHash) via sips ======================================
-- Computes a 64-bit difference hash for visual duplicate detection.
-- Uses macOS built-in `sips` to resize to 9x8 BMP, then parses the BMP
-- pixel data in pure Lua. No external dependencies.
-- Handles both 24-bit (RGB) and 32-bit (RGBA) BMPs — modern macOS sips
-- often produces 32-bit BMPs even for opaque images.

local function parseBmpGrayscale(path)
    local data = M.readBinaryFile(path)
    if not data or #data < 54 then return nil end

    local function u32(offset)
        local b1, b2, b3, b4 = data:byte(offset, offset + 3)
        return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    end
    -- Signed 32-bit — needed for BMP height (negative = top-down)
    local function s32(offset)
        local val = u32(offset)
        if val >= 2147483648 then val = val - 4294967296 end
        return val
    end
    local function u16(offset)
        local b1, b2 = data:byte(offset, offset + 1)
        return b1 + b2 * 256
    end

    local pixelOffset = u32(11)
    local width       = u32(19)
    local rawHeight   = s32(23)
    local bpp         = u16(29)

    -- Negative height means top-down row order (common in modern macOS sips output)
    local topDown = rawHeight < 0
    local height  = math.abs(rawHeight)

    -- Support both 24-bit (RGB) and 32-bit (RGBA) BMPs
    local bytesPerPixel
    if bpp == 24 then
        bytesPerPixel = 3
    elseif bpp == 32 then
        bytesPerPixel = 4
    else
        return nil
    end

    local rowBytes = math.ceil(width * bytesPerPixel / 4) * 4

    local rows = {}
    for y = 0, height - 1 do
        local row = {}
        local rowStart
        if topDown then
            rowStart = pixelOffset + y * rowBytes
        else
            rowStart = pixelOffset + (height - 1 - y) * rowBytes
        end
        for x = 0, width - 1 do
            local pixStart = rowStart + x * bytesPerPixel + 1
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
