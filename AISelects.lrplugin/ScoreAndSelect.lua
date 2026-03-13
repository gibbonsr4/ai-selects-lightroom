--[[
  ScoreAndSelect.lua
  ─────────────────────────────────────────────────────────────────────────────
  Primary entry point for AI Selects. Shows a run configuration dialog with
  mode, story settings, target count, and weights, then runs Pass 1 (Score)
  followed by Pass 2 (Select) sequentially.

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

-- ── Build story preset dropdown items ────────────────────────────────────
local function buildPresetItems()
    local items = {}
    for _, preset in ipairs(StoryPresets.presets) do
        items[#items + 1] = { title = preset.name, value = preset.id }
    end
    return items
end

-- ── Lookup preset by ID ──────────────────────────────────────────────────
local function getPresetById(id)
    return StoryPresets.getPreset(id)
end

-- ── Run configuration dialog ─────────────────────────────────────────────
-- Returns settings table or nil if user canceled.
local function showRunDialog(context)
    local current = Prefs.getPrefs()
    local f       = LrView.osFactory()

    local props = LrBinding.makePropertyTable(context)

    -- Pre-fill from saved prefs
    props.selectionMode         = current.selectionMode or "bestof"
    props.targetCount           = tostring(current.targetCount)
    props.technicalPct          = tostring(current.technicalPct)
    props.varietyMode            = current.varietyMode or "proportional"
    props.storyPreset           = current.storyPreset or "family_vacation"
    props.storyCustomInstructions = current.storyCustomInstructions or ""
    props.enableCalibration       = current.enableCalibration

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
                f:static_text {
                    title      = "Optional. Appended to any preset to further guide the AI.",
                    text_color = LrView.kDisabledColor,
                },
            },
        },

        -- ═══════════════════════════════════════════════════════════
        -- SELECTION SETTINGS
        -- ═══════════════════════════════════════════════════════════
        f:group_box {
            title           = "Selection",
            fill_horizontal = 1,

            f:row {
                f:static_text {
                    title     = "Target count:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:edit_field {
                    value          = LrView.bind("targetCount"),
                    width_in_chars = 5,
                },
                f:static_text { title = "photos to select" },
            },
            f:row {
                f:static_text {
                    title     = "Technical emphasis:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:edit_field {
                    value          = LrView.bind("technicalPct"),
                    width_in_chars = 4,
                },
                f:static_text { title = "%" },
                f:static_text {
                    title      = LrView.bind {
                        key = "technicalPct",
                        transform = function(value)
                            local pct = tonumber(value) or 40
                            return string.format("(%d%% technical, %d%% aesthetic)", pct, 100 - pct)
                        end,
                    },
                    text_color = LrView.kDisabledColor,
                },
            },
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share("run_label_width"),
                },
                f:static_text {
                    title      = "How much to weight technical quality vs. aesthetic appeal. Default: 40%.",
                    text_color = LrView.kDisabledColor,
                },
            },
            -- Variety mode (Best Of only)
            f:row {
                visible = LrView.bind {
                    key   = "selectionMode",
                    transform = function(value) return value == "bestof" end,
                },
                f:static_text {
                    title     = "Variety mode:",
                    width     = LrView.share("run_label_width"),
                    alignment = "right",
                },
                f:popup_menu {
                    value = LrView.bind("varietyMode"),
                    items = {
                        { title = "Proportional (match original mix)",  value = "proportional" },
                        { title = "Equal (balance across categories)",  value = "equal"        },
                    },
                },
            },
            f:row {
                f:static_text {
                    title = "",
                    width = LrView.share("run_label_width"),
                },
                f:checkbox {
                    title = "Calibrate scores to this collection (samples photos first)",
                    value = LrView.bind("enableCalibration"),
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
        local pct = tonumber(values.technicalPct)
        if not pct or pct < 0 or pct > 100 then
            return false, "Technical emphasis must be between 0 and 100."
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
                keys = { "targetCount", "technicalPct" },
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
    prefs.selectionMode         = props.selectionMode
    prefs.targetCount           = math.floor(tonumber(props.targetCount))
    prefs.technicalPct          = math.floor(tonumber(props.technicalPct))
    prefs.varietyMode            = props.varietyMode
    prefs.storyPreset           = props.storyPreset
    prefs.storyCustomInstructions = props.storyCustomInstructions
    prefs.enableCalibration       = props.enableCalibration

    -- Return overrides for the selection pass
    return {
        selectionMode         = props.selectionMode,
        targetCount           = math.floor(tonumber(props.targetCount)),
        technicalPct          = math.floor(tonumber(props.technicalPct)),
        varietyMode            = props.varietyMode,
        storyPreset           = props.storyPreset,
        storyCustomInstructions = props.storyCustomInstructions,
        enableCalibration       = props.enableCalibration,
    }
end

-- ── Calibration results dialog ──────────────────────────────────────────
-- Shows calibration stats and lets user adjust technical/aesthetic weight.
-- Returns updated technicalPct or nil if canceled.
local function showCalibrationDialog(context, calStats, currentTechnicalPct)
    local f = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)

    props.technicalPct = tostring(currentTechnicalPct)

    local contents = f:column {
        spacing         = f:dialog_spacing(),
        fill_horizontal = 1,
        bind_to_object  = props,

        f:static_text {
            title = string.format("Sampled %d of your photos to establish a scoring baseline.",
                calStats.sampleCount),
        },

        f:separator { fill_horizontal = 1 },

        -- Per-dimension stats
        f:row {
            f:static_text {
                title     = "Technical scores:",
                width     = LrView.share("cal_label_width"),
                alignment = "right",
            },
            f:static_text {
                title = string.format("%d — %d  (mean %.1f)",
                    calStats.techMin, calStats.techMax, calStats.techMean),
            },
        },
        f:row {
            f:static_text {
                title     = "Aesthetic scores:",
                width     = LrView.share("cal_label_width"),
                alignment = "right",
            },
            f:static_text {
                title = string.format("%d — %d  (mean %.1f)",
                    calStats.aestMin, calStats.aestMax, calStats.aestMean),
            },
        },
        f:row {
            f:static_text {
                title     = "Combined range:",
                width     = LrView.share("cal_label_width"),
                alignment = "right",
            },
            f:static_text {
                title = string.format("%d — %d  (mean %.1f, stddev %.1f)",
                    calStats.min, calStats.max, calStats.mean, calStats.stddev),
            },
        },

        f:separator { fill_horizontal = 1 },

        -- Best/worst samples
        f:row {
            f:static_text {
                title     = "Best sample:",
                width     = LrView.share("cal_label_width"),
                alignment = "right",
            },
            f:static_text {
                title = string.format("\"%s\" (scored %d/10)",
                    calStats.bestContent:sub(1, 60), calStats.max),
            },
        },
        f:row {
            f:static_text {
                title     = "Weakest sample:",
                width     = LrView.share("cal_label_width"),
                alignment = "right",
            },
            f:static_text {
                title = string.format("\"%s\" (scored %d/10)",
                    calStats.worstContent:sub(1, 60), calStats.min),
            },
        },

        f:separator { fill_horizontal = 1 },

        -- Adjustable weight
        f:row {
            f:static_text {
                title     = "Technical emphasis:",
                width     = LrView.share("cal_label_width"),
                alignment = "right",
            },
            f:edit_field {
                value          = LrView.bind("technicalPct"),
                width_in_chars = 4,
            },
            f:static_text { title = "%" },
            f:static_text {
                title      = LrView.bind {
                    key = "technicalPct",
                    transform = function(value)
                        local pct = tonumber(value) or 40
                        return string.format("(%d%% technical, %d%% aesthetic)", pct, 100 - pct)
                    end,
                },
                text_color = LrView.kDisabledColor,
            },
        },
        f:row {
            f:static_text {
                title = "",
                width = LrView.share("cal_label_width"),
            },
            f:static_text {
                title      = "Adjust based on the calibration results above.\nHigher = favor sharper images. Lower = favor more visually compelling images.",
                text_color = LrView.kDisabledColor,
                height_in_lines = 2,
            },
        },

        -- Validation
        f:row {
            f:static_text {
                title = "",
                width = LrView.share("cal_label_width"),
            },
            f:static_text {
                title           = LrView.bind("validationMessage"),
                text_color      = LrView.kWarningColor,
                fill_horizontal = 1,
            },
        },
    }

    props.validationMessage = ""

    local result = LrDialogs.presentModalDialog {
        title      = "AI Selects - Calibration Results",
        contents   = contents,
        actionVerb = "Continue Scoring",
        actionBinding = {
            enabled = {
                bind_to_object = props,
                keys = { "technicalPct" },
                operation = function(_, values)
                    local pct = tonumber(values.technicalPct)
                    if not pct or pct < 0 or pct > 100 then
                        props.validationMessage = "Technical emphasis must be between 0 and 100."
                        return false
                    end
                    props.validationMessage = ""
                    return true
                end,
            },
        },
    }

    if result ~= "ok" then return nil end

    return math.floor(tonumber(props.technicalPct))
end

-- ── Main execution ──────────────────────────────────────────────────────

-- Signal to ScorePhotos/SelectPhotos: return module, don't start standalone task
_G._AI_SELECTS_MODULE_LOAD = true

local ScoreModule  = dofile(_PLUGIN.path .. '/ScorePhotos.lua')
local SelectModule = dofile(_PLUGIN.path .. '/SelectPhotos.lua')

_G._AI_SELECTS_MODULE_LOAD = nil  -- clean up

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext("AISelectsScoreAndSelect", function(context)
        local ok, err = LrTasks.pcall(function()

            -- Show run config dialog
            local overrides = showRunDialog(context)
            if not overrides then return end  -- user canceled

            -- Calibration pass (if enabled)
            local calResult = ScoreModule.runCalibration(context)
            if not calResult then return end  -- canceled or error

            if calResult.calibrationStats then
                -- Show calibration results and let user adjust weights
                local newPct = showCalibrationDialog(
                    context, calResult.calibrationStats, overrides.technicalPct)
                if not newPct then return end  -- user canceled
                overrides.technicalPct = newPct
                -- Save updated weight to prefs
                local prefs = LrPrefs.prefsForPlugin()
                prefs.technicalPct = newPct
            end

            -- Pass 1: Score (with calibration result, skips re-calibration)
            local successCount, errorCount, skipCount, scoreSummary =
                ScoreModule.runScoring(context, calResult)

            if not scoreSummary then
                return  -- user canceled or no photos
            end

            LrDialogs.message("AI Selects - Scoring Complete", scoreSummary, "info")

            if successCount == 0 and skipCount == 0 then
                return  -- nothing scored and nothing previously scored
            end

            -- Pass 2: Select (with overrides from run dialog)
            local selectSummary = SelectModule.runSelection(context, overrides)

            if selectSummary then
                LrDialogs.message("AI Selects - Selection Complete", selectSummary, "info")
            end

        end)
        if not ok then
            LrDialogs.message("AI Selects - Error",
                "An unexpected error occurred:\n\n" .. tostring(err), "critical")
        end
    end)
end)
