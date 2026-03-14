--[[
  ScoreAndSelect.lua
  ─────────────────────────────────────────────────────────────────────────────
  Primary entry point for AI Selects. Shows a run configuration dialog with
  mode, story settings, scoring quality, emphasis slider, and target count,
  then runs Pass 1 (Score) followed by Pass 2 (Select) sequentially.

  v2: Nitpicky scale replaces calibration. Emphasis slider replaces
      percentage input. Pass 2 refinement checkbox for story mode.
      Batch size override. Snapshots flow from scoring into story selection.

  Settings from the run dialog are saved to prefs so they persist between runs.
  Provider/model/logging configuration is in Settings (Config.lua).

  macOS only.
--]]

local LrApplication     = import 'LrApplication'
local LrBinding         = import 'LrBinding'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs           = import 'LrPrefs'
local LrTasks           = import 'LrTasks'
local LrView            = import 'LrView'

local Prefs        = dofile(_PLUGIN.path .. '/Prefs.lua')
local StoryPresets = dofile(_PLUGIN.path .. '/StoryPresets.lua')

-- ── Build story preset dropdown items ──────────────────────────────────────
local function buildPresetItems()
    local items = {}
    for _, preset in ipairs(StoryPresets.presets) do
        items[#items + 1] = { title = preset.name, value = preset.id }
    end
    return items
end

-- ── Lookup preset by ID ────────────────────────────────────────────────────
local function getPresetById(id)
    return StoryPresets.getPreset(id)
end

-- ── Run configuration dialog ───────────────────────────────────────────────
-- Returns settings table or nil if user canceled.
local function showRunDialog(context)
    local current = Prefs.getPrefs()
    local f       = LrView.osFactory()

    local props = LrBinding.makePropertyTable(context)

    -- Pre-fill from saved prefs
    props.selectionMode          = current.selectionMode or "bestof"
    props.targetCount            = tostring(current.targetCount or 40)
    props.emphasisSlider         = current.emphasisSlider or 50
    props.nitpickyScale          = current.nitpickyScale or "consumer"
    props.storyPreset            = current.storyPreset or "family_vacation"
    props.storyCustomInstructions = current.storyCustomInstructions or ""  -- v2 fallback only
    props.skipScored             = current.skipScored or false
    props.batchSize              = tostring(current.batchSize or 0)
    props.preHints               = current.preHints or ""

    -- Preset description (dynamic)
    local preset = getPresetById(props.storyPreset)
    props.presetDescription = preset and preset.description or ""

    -- Provider info (read-only display)
    local providerLabel
    if current.provider == "claude" then
        providerLabel = "Claude API — " .. current.claudeModel
    elseif current.provider == "openai" then
        providerLabel = "OpenAI API — " .. current.openaiModel
    elseif current.provider == "gemini" then
        providerLabel = "Gemini API — " .. current.geminiModel
    else
        providerLabel = "Ollama — " .. current.model
    end
    props.providerInfo = providerLabel

    -- Update preset description when selection changes
    props:addObserver("storyPreset", function(_, _, newValue)
        local p = getPresetById(newValue)
        props.presetDescription = p and p.description or ""
    end)

    -- Count selected photos
    local catalog = LrApplication.activeCatalog()
    local targetPhotos = catalog:getTargetPhotos()
    local photoCount = #targetPhotos
    props.photoCountInfo = string.format("%d photo(s) selected", photoCount)

    -- Emphasis label (dynamic)
    props.emphasisLabel = ""
    local function updateEmphasisLabel()
        local val = props.emphasisSlider or 50
        if val <= 15 then
            props.emphasisLabel = "Heavy technical"
        elseif val <= 35 then
            props.emphasisLabel = "Technical-leaning"
        elseif val <= 65 then
            props.emphasisLabel = "Balanced"
        elseif val <= 85 then
            props.emphasisLabel = "Creative-leaning"
        else
            props.emphasisLabel = "Heavy creative"
        end
    end
    updateEmphasisLabel()
    props:addObserver("emphasisSlider", function() updateEmphasisLabel() end)

    local contents = f:column {
        spacing         = f:dialog_spacing(),
        fill_horizontal = 1,
        bind_to_object  = props,

        -- Photo count info
        f:row {
            f:static_text {
                title      = LrView.bind("photoCountInfo"),
                text_color = LrView.kDisabledColor,
            },
        },

        f:separator { fill_horizontal = 1 },

        -- ═══════════════════════════════════════════════════════════
        -- MODE SELECTOR
        -- ═══════════════════════════════════════════════════════════
        f:row {
            f:static_text {
                title     = "Mode:",
                width     = LrView.share("run_label_width"),
                alignment = "right",
            },
            f:radio_button {
                title         = "Best Of (quality cull)",
                value         = LrView.bind("selectionMode"),
                checked_value = "bestof",
            },
            f:radio_button {
                title         = "Story (narrative edit)",
                value         = LrView.bind("selectionMode"),
                checked_value = "story",
            },
        },

        -- ═══════════════════════════════════════════════════════════
        -- STORY SETTINGS (visible when mode = "story")
        -- ═══════════════════════════════════════════════════════════
        f:group_box {
            title           = "Story Settings",
            fill_horizontal = 1,
            visible         = LrView.bind {
                key   = "selectionMode",
                transform = function(value) return value == "story" end,
            },

            f:row {
                f:static_text {
                    title     = "Preset:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:popup_menu {
                    value = LrView.bind("storyPreset"),
                    items = buildPresetItems(),
                },
            },
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share("run_label_width"),
                },
                f:static_text {
                    title           = LrView.bind("presetDescription"),
                    text_color      = LrView.kDisabledColor,
                    fill_horizontal = 1,
                    height_in_lines = 2,
                    width_in_chars  = 50,
                },
            },
            -- (v2 "Additional instructions" field and "Refine selections" checkbox
            -- removed — replaced by preHints + v3 story dialog)
        },

        -- ═══════════════════════════════════════════════════════════
        -- SCORING SETTINGS
        -- ═══════════════════════════════════════════════════════════
        f:group_box {
            title           = "Scoring",
            fill_horizontal = 1,

            -- Input quality (nitpicky scale)
            f:row {
                f:static_text {
                    title     = "Input quality:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:radio_button {
                    title         = "Consumer",
                    value         = LrView.bind("nitpickyScale"),
                    checked_value = "consumer",
                },
                f:radio_button {
                    title         = "Enthusiast",
                    value         = LrView.bind("nitpickyScale"),
                    checked_value = "enthusiast",
                },
                f:radio_button {
                    title         = "Professional",
                    value         = LrView.bind("nitpickyScale"),
                    checked_value = "professional",
                },
            },
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share("run_label_width"),
                },
                f:static_text {
                    title      = "Sets scoring expectations. Consumer = generous, Professional = discriminating.",
                    text_color = LrView.kDisabledColor,
                },
            },

            -- Target count
            f:row {
                f:static_text {
                    title     = "Target:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:edit_field {
                    value          = LrView.bind("targetCount"),
                    width_in_chars = 5,
                },
                f:static_text { title = "photos" },
            },

            -- Emphasis slider
            f:row {
                f:static_text {
                    title     = "Emphasis:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:static_text { title = "Technical" },
                f:slider {
                    value   = LrView.bind("emphasisSlider"),
                    min     = 0,
                    max     = 100,
                    width   = 200,
                },
                f:static_text { title = "Creative" },
                f:static_text {
                    title      = LrView.bind("emphasisLabel"),
                    text_color = LrView.kDisabledColor,
                    width_in_chars = 18,
                },
            },

            -- Skip already scored
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share("run_label_width"),
                },
                f:checkbox {
                    title = "Skip already-scored photos",
                    value = LrView.bind("skipScored"),
                },
            },

            -- Batch size override (advanced)
            f:row {
                f:static_text {
                    title     = "Batch size:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:edit_field {
                    value          = LrView.bind("batchSize"),
                    width_in_chars = 4,
                },
                f:static_text {
                    title      = "(0 = auto)",
                    text_color = LrView.kDisabledColor,
                },
            },

            -- Pre-hints (optional context for scoring)
            f:row {
                f:static_text {
                    title     = "Context:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:edit_field {
                    value           = LrView.bind("preHints"),
                    width_in_chars  = 50,
                    height_in_lines = 2,
                },
            },
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share("run_label_width"),
                },
                f:static_text {
                    title      = "Optional hints for scoring. E.g., \"the older man is my dad\", \"this is from 2007\".",
                    text_color = LrView.kDisabledColor,
                },
            },
        },

        -- ═══════════════════════════════════════════════════════════
        -- PROVIDER INFO (read-only)
        -- ═══════════════════════════════════════════════════════════
        f:row {
            f:static_text {
                title     = "Using:",
                width     = LrView.share("run_label_width"),
                alignment = "right",
            },
            f:static_text {
                title = LrView.bind("providerInfo"),
            },
            f:static_text {
                title      = "(change in Settings)",
                text_color = LrView.kDisabledColor,
            },
        },

        f:separator { fill_horizontal = 1 },
        f:row {
            f:static_text {
                title = "",
                width = LrView.share("run_label_width"),
            },
            f:static_text {
                title      = "Photos are scored in capture-time order. For best results, ensure your "
                          .. "photos have accurate capture times (EXIF date). Story mode relies on "
                          .. "chronological order to build a coherent narrative.",
                text_color = LrView.kDisabledColor,
                fill_horizontal = 1,
                height_in_lines = 2,
                width_in_chars  = 55,
            },
        },

        -- Validation
        f:row {
            f:static_text {
                title = "",
                width = LrView.share("run_label_width"),
            },
            f:static_text {
                title           = LrView.bind("validationMessage"),
                text_color      = LrView.kWarningColor,
                fill_horizontal = 1,
            },
        },
    }

    -- Validation
    local function validateRunSettings(values)
        local target = tonumber(values.targetCount)
        if not target or target < 1 then
            return false, "Target count must be a positive number."
        end
        local bs = tonumber(values.batchSize)
        if bs and bs < 0 then
            return false, "Batch size must be 0 (auto) or a positive number."
        end
        if photoCount == 0 then
            return false, "No photos selected. Select photos in the Library grid first."
        end
        return true, ""
    end

    props.validationMessage = ""
    local valid, msg = validateRunSettings(props)
    props.validationMessage = msg

    local result = LrDialogs.presentModalDialog {
        title      = "AI Selects",
        contents   = contents,
        actionVerb = "Run",
        actionBinding = {
            enabled = {
                bind_to_object = props,
                keys = { "targetCount", "batchSize" },
                operation = function(_, values)
                    local isValid, validMsg = validateRunSettings(values)
                    props.validationMessage = validMsg
                    return isValid
                end,
            },
        },
    }

    if result ~= "ok" then return nil end

    -- Save run dialog settings back to prefs
    local prefs = LrPrefs.prefsForPlugin()
    prefs.selectionMode          = props.selectionMode
    prefs.targetCount            = math.floor(tonumber(props.targetCount))
    prefs.emphasisSlider         = math.floor(props.emphasisSlider)
    prefs.nitpickyScale          = props.nitpickyScale
    prefs.storyPreset            = props.storyPreset
    prefs.storyCustomInstructions = props.storyCustomInstructions  -- v2 fallback only
    prefs.skipScored             = props.skipScored
    prefs.batchSize              = math.floor(tonumber(props.batchSize) or 0)
    prefs.preHints               = props.preHints

    -- Return overrides for scoring and selection passes
    return {
        selectionMode          = props.selectionMode,
        targetCount            = math.floor(tonumber(props.targetCount)),
        emphasisSlider         = math.floor(props.emphasisSlider),
        nitpickyScale          = props.nitpickyScale,
        storyPreset            = props.storyPreset,
        storyCustomInstructions = props.storyCustomInstructions,  -- v2 fallback only
        skipScored             = props.skipScored,
        batchSize              = math.floor(tonumber(props.batchSize) or 0),
        preHints               = props.preHints,
    }
end

-- ── Mid-run story dialog (shown after Pass 1, story mode only) ───────────
-- Shows prepopulated AI summary + editable story prompt + emphasis field.
-- Returns (storyPrompt, emphasis) or nil if user canceled.
local function showStoryDialog(context, prepopulatedSummary, draftPrompt, currentTargetCount)
    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)

    props.aiSummary     = prepopulatedSummary or "(No summary available)"
    props.storyPrompt   = draftPrompt or ""
    props.storyEmphasis = ""
    props.targetCount   = tostring(currentTargetCount or 40)

    local contents = f:column {
        spacing         = f:dialog_spacing(),
        fill_horizontal = 1,
        bind_to_object  = props,

        f:static_text {
            title      = "What we found in your photos:",
            font       = "<system/bold>",
        },

        f:edit_field {
            value           = LrView.bind("aiSummary"),
            width_in_chars  = 60,
            height_in_lines = 6,
            wraps           = true,
        },

        f:separator { fill_horizontal = 1 },

        f:static_text {
            title = "Your story (edit, add details, correct anything above):",
            font  = "<system/bold>",
        },

        f:edit_field {
            value           = LrView.bind("storyPrompt"),
            width_in_chars  = 60,
            height_in_lines = 6,
            wraps           = true,
        },

        f:static_text {
            title      = "This will guide how photos are selected and ordered. Be specific about what matters.",
            text_color = LrView.kDisabledColor,
        },

        f:separator { fill_horizontal = 1 },

        f:row {
            f:static_text {
                title     = "Target photos:",
                alignment = "right",
            },
            f:edit_field {
                value          = LrView.bind("targetCount"),
                width_in_chars = 5,
            },
            f:static_text {
                title      = "Adjust after seeing your scores — fewer = tighter curation",
                text_color = LrView.kDisabledColor,
            },
        },

        f:separator { fill_horizontal = 1 },

        f:static_text {
            title = "Emphasize anything? (optional):",
        },

        f:edit_field {
            value           = LrView.bind("storyEmphasis"),
            width_in_chars  = 60,
            height_in_lines = 2,
        },

        f:static_text {
            title      = "E.g., \"the dive was the highlight\", \"make sure Mom is well represented\".",
            text_color = LrView.kDisabledColor,
        },
    }

    local result = LrDialogs.presentModalDialog {
        title      = "AI Selects — Story Setup",
        contents   = contents,
        actionVerb = "Build Story",
    }

    if result ~= "ok" then return nil end

    local tc = math.floor(tonumber(props.targetCount) or 40)
    if tc < 1 then tc = 1 end
    return props.storyPrompt, props.storyEmphasis, tc
end

-- Forward declarations for modules loaded below (needed by functions defined here)
local Engine    -- loaded in main execution section
local Prefs2    -- loaded in main execution section

-- ── Build photoStore from catalog (for mid-run dialog) ───────────────────
-- Reads scored metadata from the active catalog to build a photoStore table.
-- This is a lightweight version used between Pass 1 and story dialog.
local function buildPhotoStoreFromCatalog()
    local catalog = LrApplication.activeCatalog()
    local targetPhotos = catalog:getTargetPhotos()
    local store = {}

    for _, photo in ipairs(targetPhotos) do
        local technical = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsTechnical'))
        local scoreDate = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsScoreDate')
        if not technical or not scoreDate or scoreDate == "" then
            -- not scored, skip
        else
            local composition = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsComposition'))
            if composition then
                local id = photo.localIdentifier
                local captureTime = photo:getRawMetadata('dateTimeOriginal')

                store[id] = {
                    photo       = photo,
                    filename    = photo:getFormattedMetadata('fileName'),
                    scores      = {
                        technical   = technical,
                        composition = composition,
                        emotion     = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsEmotion')) or 5,
                        moment      = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsMoment')) or 5,
                    },
                    composite   = tonumber(photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsComposite')) or 5,
                    content     = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsContent') or "unknown",
                    category    = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsCategory') or "other",
                    eyeQuality  = photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsEyeQuality') or "na",
                    reject      = (photo:getPropertyForPlugin(_PLUGIN, 'aiSelectsReject') == "true"),
                    captureTime = captureTime,
                    people      = {},
                }
            end
        end
    end

    -- Populate face data (Engine is loaded at module level below)
    local allPhotos = {}
    for _, s in pairs(store) do allPhotos[#allPhotos + 1] = s.photo end
    local faceMap = Engine.queryFacePeople(catalog, allPhotos)
    if faceMap then
        for id, s in pairs(store) do
            local names = faceMap[id]
            if names then s.people = names end
        end
    end

    return store
end

-- ── Main execution ────────────────────────────────────────────────────────

-- Signal to ScorePhotos/SelectPhotos: return module, don't start standalone task
_G._AI_SELECTS_MODULE_LOAD = true

local ScoreModule  = dofile(_PLUGIN.path .. '/ScorePhotos.lua')
local SelectModule = dofile(_PLUGIN.path .. '/SelectPhotos.lua')
Engine             = dofile(_PLUGIN.path .. '/AIEngine.lua')
Prefs2             = dofile(_PLUGIN.path .. '/Prefs.lua')

_G._AI_SELECTS_MODULE_LOAD = nil  -- clean up

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("AISelectsScoreAndSelect", function(context)

        -- Show run config dialog
        local overrides = showRunDialog(context)
        if not overrides then return end  -- user canceled

        -- Pass 1: Score (batch scoring with snapshots)
        local successCount, errorCount, skipCount, scoreSummary, allSnapshots =
            ScoreModule.runScoring(context, overrides)

        if not scoreSummary then
            return  -- user canceled or no photos
        end

        LrDialogs.message("AI Selects - Scoring Complete", scoreSummary, "info")

        if successCount == 0 and skipCount == 0 then
            return  -- nothing scored and nothing previously scored
        end

        -- ── Story mode: mid-run dialog (after Pass 1, before selection) ──
        if overrides.selectionMode == "story" then
            -- Build photoStore from freshly scored catalog data
            local photoStore = buildPhotoStoreFromCatalog()

            -- Merge full prefs with overrides for AI calls
            local fullPrefs = Prefs2.getPrefs()
            for k, v in pairs(overrides) do fullPrefs[k] = v end

            -- Generate AI prepopulated summary
            local aiSummary, prepErr = Engine.buildPrepopulationSummary(
                allSnapshots, photoStore, overrides.preHints, fullPrefs)

            if not aiSummary then
                -- Fallback to template-based summary
                aiSummary = Engine.buildPrepopulationFallback(
                    allSnapshots, photoStore, overrides.preHints)
            end

            -- Show the story dialog
            local storyPrompt, storyEmphasis, newTargetCount =
                showStoryDialog(context, aiSummary, aiSummary, overrides.targetCount)

            if not storyPrompt then
                -- User canceled — scores are saved, story assembly skipped
                LrDialogs.message("AI Selects",
                    "Scoring complete. Story assembly canceled.\n\n" ..
                    "Your scores are saved — you can run selection separately later.", "info")
                return
            end

            -- Store confirmed story prompt and updated target in overrides
            overrides.storyPrompt   = storyPrompt
            overrides.storyEmphasis = storyEmphasis
            overrides.targetCount   = newTargetCount

            -- Save to prefs for persistence
            local prefs = LrPrefs.prefsForPlugin()
            prefs.storyPrompt   = storyPrompt
            prefs.storyEmphasis = storyEmphasis
        end

        -- Selection pass (with overrides, snapshots, and story prompt if story mode)
        local selectSummary = SelectModule.runSelection(context, overrides, allSnapshots)

        if selectSummary then
            LrDialogs.message("AI Selects - Selection Complete", selectSummary, "info")
        end

    end)
end)
