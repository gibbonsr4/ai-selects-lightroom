return {
    LrSdkVersion        = 6.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = 'com.sonoranstrategy.ai-selects',
    LrPluginName        = 'AI Selects',
    LrPluginInfoUrl     = 'https://github.com/gibbonsr4/ai-selects-lightroom',

    LrMetadataProvider       = 'MetadataDefinition.lua',
    LrMetadataTagsetFactory  = 'MetadataTagset.lua',

    LrLibraryMenuItems  = {
        { title = "Score && Select",        file = "ScoreAndSelect.lua" },
        { title = "Score Only",             file = "ScorePhotos.lua"   },
        { title = "Select Only",            file = "SelectPhotos.lua"  },
        { title = "Settings\226\128\166",          file = "Config.lua"       },
    },

    VERSION = { major = 1, minor = 0, revision = 0, build = 1 },
}
