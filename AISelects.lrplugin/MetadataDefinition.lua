return {
    schemaVersion = 5,

    metadataFieldsForPhotos = {
        -- ── Scoring dimensions (v2: 4 dimensions) ──────────────────────────
        {
            id         = 'aiSelectsTechnical',
            dataType   = 'string',
            title      = 'AI Selects: Technical Score',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsComposition',
            dataType   = 'string',
            title      = 'AI Selects: Composition Score',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsEmotion',
            dataType   = 'string',
            title      = 'AI Selects: Emotion Score',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsMoment',
            dataType   = 'string',
            title      = 'AI Selects: Moment Score',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsComposite',
            dataType   = 'string',
            title      = 'AI Selects: Composite Score',
            searchable = true,
            browsable  = true,
        },

        -- ── Descriptive fields ──────────────────────────────────────────────
        {
            id         = 'aiSelectsContent',
            dataType   = 'string',
            title      = 'AI Selects: Content',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsCategory',
            dataType   = 'string',
            title      = 'AI Selects: Category',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsEyeQuality',
            dataType   = 'string',
            title      = 'AI Selects: Eye Quality',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsNarrativeRole',
            dataType   = 'string',
            title      = 'AI Selects: Narrative Role',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsReject',
            dataType   = 'string',
            title      = 'AI Selects: Reject',
            searchable = true,
            browsable  = true,
        },

        -- ── Internal / debugging fields ─────────────────────────────────────
        {
            id         = 'aiSelectsPhash',
            dataType   = 'string',
            title      = 'AI Selects: Perceptual Hash',
            searchable = false,
            browsable  = false,
        },
        {
            id         = 'aiSelectsScoreDate',
            dataType   = 'string',
            title      = 'AI Selects: Score Date',
            searchable = false,
            browsable  = false,
        },
        {
            id         = 'aiSelectsBatchId',
            dataType   = 'string',
            title      = 'AI Selects: Batch ID',
            searchable = false,
            browsable  = false,
        },

        -- ── Story mode fields ───────────────────────────────────────────────
        {
            id         = 'aiSelectsSequence',
            dataType   = 'string',
            title      = 'AI Selects: Sequence',
            searchable = true,
            browsable  = true,
        },
        {
            id         = 'aiSelectsStoryNote',
            dataType   = 'string',
            title      = 'AI Selects: Story Note',
            searchable = true,
            browsable  = true,
        },

        -- ── Deprecated (v1 migration — preserved for read-back) ────────────
        {
            id         = 'aiSelectsAesthetic',
            dataType   = 'string',
            title      = 'AI Selects: Aesthetic Score (v1)',
            searchable = true,
            browsable  = true,
        },
    },
}
