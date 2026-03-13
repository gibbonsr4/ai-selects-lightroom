--[[
  StoryPresets.lua
  ─────────────────────────────────────────────────────────────────────────────
  Story mode presets for AI narrative selection.
  Each preset provides guidelines that shape the AI's curation decisions.

  Used by SelectPhotos.lua (story mode) and ScoreAndSelect.lua (run dialog).

  Module exports:
    .presets    — ordered array of preset tables (for UI dropdowns)
    .getPreset(id)  — lookup a preset by its id string
--]]

local M = {}

-- Ordered list — determines dropdown order in the run dialog
M.presets = {
    {
        id          = "family_vacation",
        name        = "Family Vacation",
        description = "A warm chronological story of people, places, and moments. "
                   .. "Prioritizes connection, laughter, and sense of place.",
        guidelines  = [[Build a warm, chronological family vacation story.
Prioritize:
- Opening with an establishing/scene-setting shot (arrival, destination overview)
- People moments: candid laughter, togetherness, genuine emotion over posed shots
- Mix of wide scene-setters and tight character moments
- Key activities and experiences (meals, excursions, play)
- Environmental/detail shots that capture the feel of the place
- Transitions between days or locations
- A strong closing image (sunset, departure, group shot, quiet reflection)
Avoid:
- Too many similar group poses in a row
- Overloading on landscape-only shots without people
- Clustering all the best shots at the beginning]],
        requiredRoles      = { "scene_setter", "character_moment", "detail", "closing" },
        requiredCategories = {},
        peopleEmphasis     = "high",
        chronological      = true,
    },

    {
        id          = "landscape_portfolio",
        name        = "Landscape Portfolio",
        description = "A curated nature and landscape portfolio optimized for "
                   .. "visual impact and variety. Quality over narrative.",
        guidelines  = [[Curate a landscape/nature photography portfolio.
Prioritize:
- Technical excellence: sharpness, dynamic range, clean exposure
- Compositional strength: leading lines, rule of thirds, depth
- Variety of scenes: wide vistas, intimate details, water, sky, texture
- Lighting diversity: golden hour, blue hour, dramatic weather, soft light
- Visual flow: alternate between wide establishing shots and tighter details
- Color palette variety across the selection
Avoid:
- Multiple near-identical compositions of the same scene
- Overloading on one type of landscape (e.g., all sunsets)
- People-heavy shots unless they add scale or narrative
- Technically weak images even if the scene is dramatic]],
        requiredRoles      = { "scene_setter", "detail", "establishing" },
        requiredCategories = { "landscape" },
        peopleEmphasis     = "low",
        chronological      = false,
    },

    {
        id          = "documentary_travel",
        name        = "Documentary Travel",
        description = "A journalistic travel story balancing culture, people, "
                   .. "and place. Tells the story of the destination.",
        guidelines  = [[Build a documentary-style travel story.
Prioritize:
- Opening with a strong establishing shot that sets the location
- Cultural immersion: local people, markets, food, architecture, street life
- Mix of wide environmental shots and intimate human moments
- Candid over posed — capture authentic interactions and daily life
- Architectural and historical details that define the place
- Food and dining as cultural touchpoints
- Transportation, movement, transition shots between locations
- Closing with a reflective or iconic image of the destination
Avoid:
- Tourist-selfie style shots
- Overloading on architecture without human context
- Ignoring the people and culture in favor of scenery only
- Repetitive compositions of similar subjects]],
        requiredRoles      = { "scene_setter", "character_moment", "action", "detail", "establishing", "closing" },
        requiredCategories = {},
        peopleEmphasis     = "medium",
        chronological      = true,
    },

    {
        id          = "fun_playful",
        name        = "Fun / Playful",
        description = "An energetic, joyful collection emphasizing laughter, "
                   .. "action, and spontaneous moments.",
        guidelines  = [[Curate an energetic, joyful collection.
Prioritize:
- Laughter, smiles, genuine joy and surprise
- Action and movement: jumping, running, playing, dancing
- Candid spontaneous moments over posed shots
- Bright, vibrant images with positive energy
- Group dynamics and interaction
- Funny or unexpected moments
- Playful details: food mess, silly faces, costume elements
- Visual variety in framing and perspective
Avoid:
- Serious, contemplative, or melancholy images
- Static posed group photos (unless everyone is genuinely laughing)
- Dark, moody lighting unless the moment is genuinely fun
- Overly similar shots of the same activity]],
        requiredRoles      = { "character_moment", "action", "emotional_peak" },
        requiredCategories = {},
        peopleEmphasis     = "high",
        chronological      = false,
    },

    {
        id          = "wedding",
        name        = "Wedding",
        description = "A romantic wedding story capturing ceremony, emotion, "
                   .. "details, and celebration from start to finish.",
        guidelines  = [[Build a romantic, chronological wedding story.
Prioritize:
- Opening with preparation shots: getting ready, details (dress, rings, flowers, venue)
- Ceremony highlights: processional, vows, first kiss, recessional
- Genuine emotion: tears of joy, laughter, nervous anticipation, proud parents
- Couple portraits and candid moments of connection
- Key reception moments: first dance, toasts, cake cutting, parent dances
- Guest reactions and candid celebration
- Detail shots: table settings, decor, invitation, bouquet, shoes
- Dancing and party energy
- A strong closing image: sparkler exit, last dance, quiet couple moment
Avoid:
- Too many near-identical posed group photos
- Overloading on detail/decor shots at the expense of emotion
- Missing any major wedding milestone (ceremony, reception, first dance)
- Back-to-back shots of the same moment from similar angles]],
        requiredRoles      = { "scene_setter", "character_moment", "action", "detail", "emotional_peak", "closing" },
        requiredCategories = {},
        peopleEmphasis     = "high",
        chronological      = true,
    },

    {
        id          = "portrait_session",
        name        = "Portrait Session",
        description = "A polished portrait session edit emphasizing expression, "
                   .. "variety, and the subject's personality.",
        guidelines  = [[Curate a polished portrait session selection.
Prioritize:
- Sharp eyes and engaging expressions above all else
- Variety of expressions: serious, laughing, contemplative, joyful
- Mix of compositions: tight headshots, medium shots, environmental/full-length
- Lighting variety if available: different setups, angles, or natural light shifts
- Outfit or location changes to create visual chapters
- At least one strong "hero" image suitable for large print or portfolio cover
- Flattering angles and genuine personality moments
- Background variety and clean compositions
Avoid:
- Multiple shots with the same expression and pose
- Closed eyes, mid-blink, or unflattering expressions
- Technically weak images even if the expression is good
- Shots where the background distracts from the subject
- Overloading on one focal length or composition style]],
        requiredRoles      = { "character_moment", "detail", "emotional_peak" },
        requiredCategories = { "portrait" },
        peopleEmphasis     = "high",
        chronological      = false,
    },

    {
        id          = "editorial",
        name        = "Editorial",
        description = "A magazine-style edit with strong visual narrative, "
                   .. "dramatic compositions, and cinematic pacing.",
        guidelines  = [[Curate a magazine-quality editorial selection.
Prioritize:
- Visual impact and dramatic compositions over documentary completeness
- Strong opening image: bold, graphic, attention-grabbing
- Cinematic pacing: vary between wide establishing shots and tight details
- Mood consistency: maintain a cohesive tone and color palette
- Striking light: dramatic shadows, rim light, silhouettes, golden hour
- Graphic compositions: leading lines, symmetry, negative space, bold shapes
- Environmental portraits over standard portrait framing
- Textural and abstract detail shots as visual breathers
- A closing image that resonates: powerful, quiet, or thought-provoking
Avoid:
- Snapshot-style casual images that lack visual intention
- Inconsistent mood or color temperature jumps
- Overly literal or documentary-style coverage
- Technically perfect but visually boring images
- Clustering similar compositions together]],
        requiredRoles      = { "scene_setter", "character_moment", "detail", "establishing", "closing" },
        requiredCategories = {},
        peopleEmphasis     = "medium",
        chronological      = false,
    },

    {
        id          = "custom",
        name        = "Custom",
        description = "Define your own story guidelines using the additional "
                   .. "instructions field below.",
        guidelines  = [[Curate a thoughtful photo selection based on the custom instructions provided.
Balance technical quality with narrative coherence.
Ensure variety in composition, subject, and visual rhythm.
Distribute selections across the full timeline when timestamps are available.]],
        requiredRoles      = {},
        requiredCategories = {},
        peopleEmphasis     = "medium",
        chronological      = true,
    },
}

-- Lookup a preset by ID string. Falls back to Custom if not found.
function M.getPreset(id)
    for _, preset in ipairs(M.presets) do
        if preset.id == id then return preset end
    end
    return M.presets[#M.presets]  -- fallback to last (Custom)
end

return M
