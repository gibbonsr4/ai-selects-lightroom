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
    props.storyCustomInstructions = current.storyCustomInstructions or ""
    props.enablePass2            = current.enablePass2 or false
    props.skipScored             = current.skipScored or false
    props.batchSize              = tostring(current.batchSize or 0)

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
            f:row {
                f:static_text {
                    title     = "Additional\ninstructions:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:edit_field {
                    value           = LrView.bind("storyCustomInstructions"),
                    width_in_chars  = 50,
                    height_in_lines = 3,
                },
            },
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share("run_label_width"),
                },
                f:checkbox {
                    title = "Refine selections with focused comparisons (slower)",
                    value = LrView.bind("enablePass2"),
                },
            },
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
    prefs.storyCustomInstructions = props.storyCustomInstructions
    prefs.enablePass2            = props.enablePass2
    prefs.skipScored             = props.skipScored
    prefs.batchSize              = math.floor(tonumber(props.batchSize) or 0)

    -- Return overrides for scoring and selection passes
    return {
        selectionMode          = props.selectionMode,
        targetCount            = math.floor(tonumber(props.targetCount)),
        emphasisSlider         = math.floor(props.emphasisSlider),
        nitpickyScale          = props.nitpickyScale,
        storyPreset            = props.storyPreset,
        storyCustomInstructions = props.storyCustomInstructions,
        enablePass2            = props.enablePass2,
        skipScored             = props.skipScored,
        batchSize              = math.floor(tonumber(props.batchSize) or 0),
    }
end

-- ── Main execution ────────────────────────────────────────────────────────

-- Signal to ScorePhotos/SelectPhotos: return module, don't start standalone task
_G._AI_SELECTS_MODULE_LOAD = true

local ScoreModule  = dofile(_PLUGIN.path .. '/ScorePhotos.lua')
local SelectModule = dofile(_PLUGIN.path .. '/SelectPhotos.lua')

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

        -- Pass 2: Select (with overrides and snapshots from scoring)
        local selectSummary = SelectModule.runSelection(context, overrides, allSnapshots)

        if selectSummary then
            LrDialogs.message("AI Selects - Selection Complete", selectSummary, "info")
        end

    end)
end)
