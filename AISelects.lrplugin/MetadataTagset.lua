--[[
  MetadataTagset.lua
  ---------------------------------------------------------------------------
  Defines how AI Selects custom metadata fields appear in Lightroom's
  Metadata panel. Without this file, the fields exist in the catalog but
  are not visible in the UI.

  Registered in Info.lua via LrMetadataTagsetFactory.
--]]

return {
    title = 'AI Selects',
    id    = 'aiSelectsTagset',

    items = {
        -- Show basic EXIF info first so the panel is useful on its own
        'com.adobe.filename',
        'com.adobe.folder',
        'com.adobe.dateTimeOriginal',
        'com.adobe.dimensions',

        'com.adobe.separator',

        -- AI Selects scores (v2: 4 dimensions + composite)
        { 'com.sonoranstrategy.ai-selects.aiSelectsComposite',    label = 'Composite Score'   },
        { 'com.sonoranstrategy.ai-selects.aiSelectsTechnical',    label = 'Technical'         },
        { 'com.sonoranstrategy.ai-selects.aiSelectsComposition',  label = 'Composition'       },
        { 'com.sonoranstrategy.ai-selects.aiSelectsEmotion',      label = 'Emotion'           },
        { 'com.sonoranstrategy.ai-selects.aiSelectsMoment',       label = 'Moment'            },

        'com.adobe.separator',

        -- Descriptive fields
        { 'com.sonoranstrategy.ai-selects.aiSelectsContent',       label = 'Content'          },
        { 'com.sonoranstrategy.ai-selects.aiSelectsCategory',      label = 'Category'         },
        { 'com.sonoranstrategy.ai-selects.aiSelectsEyeQuality',   label = 'Eye Quality'      },
        { 'com.sonoranstrategy.ai-selects.aiSelectsNarrativeRole', label = 'Narrative Role'   },
        { 'com.sonoranstrategy.ai-selects.aiSelectsReject',        label = 'Reject'           },
        { 'com.sonoranstrategy.ai-selects.aiSelectsScoreDate',     label = 'Score Date'       },

        'com.adobe.separator',

        -- Story mode fields (populated during narrative selection)
        { 'com.sonoranstrategy.ai-selects.aiSelectsSequence',     label = 'Sequence'          },
        { 'com.sonoranstrategy.ai-selects.aiSelectsStoryNote',    label = 'Story Note'        },
    },
}
