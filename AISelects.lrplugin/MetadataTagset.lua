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

        -- AI Selects scores
        { 'com.sonoranstrategy.ai-selects.aiSelectsTechnical',     label = 'Technical Score'  },
        { 'com.sonoranstrategy.ai-selects.aiSelectsAesthetic',     label = 'Aesthetic Score'  },
        { 'com.sonoranstrategy.ai-selects.aiSelectsContent',       label = 'Content'          },
        { 'com.sonoranstrategy.ai-selects.aiSelectsCategory',      label = 'Category'         },
        { 'com.sonoranstrategy.ai-selects.aiSelectsReject',        label = 'Reject'           },
        { 'com.sonoranstrategy.ai-selects.aiSelectsPhash',         label = 'Perceptual Hash'  },
        { 'com.sonoranstrategy.ai-selects.aiSelectsScoreDate',     label = 'Score Date'       },
        { 'com.sonoranstrategy.ai-selects.aiSelectsEyeQuality',    label = 'Eye Quality'      },
        { 'com.sonoranstrategy.ai-selects.aiSelectsNarrativeRole', label = 'Narrative Role'   },

        'com.adobe.separator',

        -- Story mode fields (populated during narrative selection)
        { 'com.sonoranstrategy.ai-selects.aiSelectsSequence',      label = 'Sequence'         },
        { 'com.sonoranstrategy.ai-selects.aiSelectsStoryNote',     label = 'Story Note'       },
    },
}
