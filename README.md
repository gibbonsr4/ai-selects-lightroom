# AI Selects — Lightroom Classic Plugin

AI-powered photo culling for Lightroom Classic. Score hundreds of photos using vision AI models, then select the best subset using quality-driven culling or AI-driven narrative storytelling.

**The problem:** Photographers routinely shoot 500+ photos per session but need 40-80 for a final deliverable. Existing culling tools handle the "thousands to hundreds" first pass (removing obvious rejects), but the "hundreds to dozens" final selection remains entirely manual. AI Selects automates this second pass using vision LLMs for scoring, combined with smart deduplication, category-aware distribution, and optional AI narrative curation.

## Features

- **Two selection modes:**
  - **Best Of** — quality-driven culling with temporal distribution across your timeline
  - **Story** — AI-driven narrative selection with a multi-pass pipeline: story assembly, vision-based beat casting, story review, and swap resolution
- **AI scoring** via Claude, OpenAI, Gemini, or local Ollama models — rates technical quality, composition, emotion, moment quality, content, narrative role, and eye quality
- **Three-layer deduplication:**
  - Burst detection (EXIF timestamps)
  - Perceptual hashing (dHash visual fingerprinting)
  - Content description similarity (AI-generated semantic comparison)
- **Category-aware selection** — groups photos by content type and distributes selections proportionally
- **Face coverage** — automatically ensures at least one photo of every named person is included, using Lightroom's built-in face detection data
- **Story presets** — Wedding, Family Vacation, Documentary Travel, Portrait Session, Editorial, Landscape Portfolio, Fun/Playful, and Custom
- **Cost tracking** — real-time API cost tracking with per-pass breakdowns
- **Non-destructive** — creates a Collection with your selects; never modifies or deletes originals
- **Zero external dependencies** — uses macOS built-in tools (`sips`, `sqlite3`, `curl`) for all processing

## Requirements

- macOS (uses `sips`, `sqlite3`, and `curl` which are built-in)
- Lightroom Classic (SDK 6.0+)
- One of:
  - **Ollama** installed locally with a vision model (free, private, no API key needed)
  - **Anthropic API key** for Claude (recommended — highest quality)
  - **Google API key** for Gemini (recommended — fastest and cheapest, ~$0.03 for 68 photos)
  - **OpenAI API key** for GPT-4o/GPT-4V

## Installation

1. Download or clone this repository
2. In Lightroom Classic, go to **File > Plug-in Manager**
3. Click **Add** and navigate to the `AISelects.lrplugin` folder
4. Click **Done**

The plugin appears under **Library > Plug-in Extras** with four menu items.

## Usage

### Quick Start

1. Select photos in the Library grid (or select All Photos in a folder)
2. Go to **Library > Plug-in Extras > Score & Select**
3. Choose your mode (Best Of or Story), adjust settings, and click **Run**
4. The plugin scores every photo via AI, then selects the best subset
5. In Story mode, a mid-run dialog lets you describe your story and adjust the target count after seeing scores
6. Your selects appear in a new Collection and Lightroom navigates to it automatically

### Menu Items

| Menu Item | Description |
|-----------|-------------|
| **Score & Select** | Shows a run dialog, then scores and selects in one pass |
| **Score Only** | Scores selected photos without running selection |
| **Select Only** | Runs selection on already-scored photos |
| **Settings...** | Configure AI provider, model, API key, render size, logging |

### Score & Select Run Dialog

The primary entry point. Shows a configuration dialog before each run:

- **Mode** — Best Of (quality cull) or Story (narrative edit)
- **Story preset** — genre-specific curation guidelines (visible in Story mode)
- **Pre-scoring hints** — context the AI uses during scoring (e.g., "this is from 2007", "the older man is my dad")
- **Target count** — how many photos to select
- **Technical emphasis** — percentage balance between technical quality and aesthetic appeal (default 40%)
- **Provider info** — shows current AI provider (change in Settings)

### Selection Modes

#### Best Of

Quality-driven culling with temporal distribution. Ensures selections are spread across your timeline, preventing clustering around a single time period.

Pipeline: Reject → Burst Dedup → Visual Dedup (dHash) → Content Dedup → Temporal Segmentation → Category Distribution → Face Coverage → Collection

#### Story (v3 Multi-Pass Pipeline)

AI-driven narrative selection using a multi-pass architecture:

```
Pass 1:   Score (AI vision — per photo)
Pre-Pass: Scene/Moment Inventory (AI text — clusters photos by WHO+WHEN+WHAT)
Pass 2:   Story Assembly (AI text — plans beats from moment inventory)
Pass 3:   Candidate Shortlisting
  3A: Code pre-filter (hard constraints per beat)
  3B: AI text ranking (order candidates by fit)
Pass 4:   Beat Casting (AI vision — compare candidates per beat, scarcity-first order)
Pass 4.5: Similarity Gate (phash — catches near-duplicate selections)
Pass 5:   Story Review (AI vision — review full selection for coherence)
Pass 6:   Swap Resolution (AI vision — targeted replacements)
```

The **Scene Inventory** clusters all photos into distinct moments using WHO (people groups), WHEN (capture time as primary signal), and WHAT (activity). This gives the story assembly a bird's-eye view of all available content, preventing duplicate beats and ensuring coverage of unique moments. The clustering is duration-adaptive — handling everything from 1-hour portrait sessions to multi-year compilations.

**Scarcity-first beat ordering** in Pass 4 processes beats with the fewest candidates first, preventing the common problem where later beats find all their candidates already consumed by earlier beats.

Before scoring, a mid-run dialog lets you describe the story in natural language and optionally emphasize specific moments. The AI pre-populates a summary based on what it saw during scoring.

**Story presets:**

| Preset | Description | Chronological | People |
|--------|-------------|:---:|:---:|
| Family Vacation | Warm story of people, places, and moments | Yes | High |
| Documentary Travel | Journalistic travel: culture, people, place | Yes | Medium |
| Wedding | Ceremony, emotion, details, and celebration | Yes | High |
| Portrait Session | Expression variety and personality | No | High |
| Editorial | Magazine-style dramatic compositions | No | Medium |
| Landscape Portfolio | Curated nature/landscape for visual impact | No | Low |
| Fun / Playful | Energetic, joyful, laughter and action | No | High |
| Custom | User-defined via story prompt | Yes | Medium |

In Story mode, set sort order to **Custom Order** in the toolbar to view photos in narrative sequence.

## AI Scoring

Each photo is rendered as a JPEG at the configured render size, base64-encoded, and sent to the AI model in batches. The AI returns:

| Field | Description |
|-------|-------------|
| **Technical** (1-10) | Sharpness, exposure, noise, white balance |
| **Composition** (1-10) | Framing, leading lines, rule of thirds, visual balance |
| **Emotion** (1-10) | Mood, feeling, emotional resonance |
| **Moment** (1-10) | Timing, decisive moment, peak action |
| **Content** | 3-5 word description of the subject/scene |
| **Category** | Primary visual element (landscape, portrait, wildlife, architecture, food, street) |
| **Narrative Role** | Editorial role (scene_setter, character_moment, action, detail, transition, closing, establishing, emotional_peak) |
| **Eye Quality** | Eye quality for visible people (good, fair, closed, na) |
| **Reject** | true if obviously bad (blurry, badly exposed, accidental shot) |

Scores are stored in Lightroom's custom metadata — visible in the Metadata panel under the "AI Selects" tagset.

### Composite Score

Photos are ranked by a weighted composite score:

```
compositeScore = technical * (techPct / 100)
               + composition * (1 - techPct / 100) * 0.4
               + emotion * (1 - techPct / 100) * 0.3
               + moment * (1 - techPct / 100) * 0.3
               + eyePenalty
```

Closed or squinting eyes receive a -1.5 penalty; all other eye states have no adjustment.

The default technical emphasis is 40%, meaning aesthetic dimensions (composition, emotion, moment) carry 60% of the weight. Adjust in the run dialog.

## How It Works

### Deduplication (Three Layers)

**1. Burst Detection** — Groups photos taken within a configurable time window (default 2 seconds) by EXIF timestamp. Keeps the highest-scoring photo from each burst.

**2. Perceptual Hashing (dHash)** — Computes a 64-bit visual fingerprint for each photo:
1. Resize to 9×8 pixels using macOS `sips`
2. Convert to grayscale
3. Compare adjacent pixels to produce 64 bits
4. Compare hashes via Hamming distance — under 10 bits different = visually similar

Catches duplicates that timestamp detection misses: returning to the same scene later, multiple compositions of the same subject.

**3. Content Description Similarity** — Compares AI-generated content descriptions using word overlap. If two photos taken within 60 seconds share 60%+ word overlap, the lower-scored one is removed. Catches semantic duplicates that pixel-level hashing misses.

### Face Detection & Coverage

Uses Lightroom's built-in face detection to ensure every named person appears at least once in the final selects:

1. Queries the catalog database (read-only) for face detection data
2. After selection runs, checks which named people are missing
3. Adds the highest-scoring photo of each missing person

**Setup:** Use Lightroom's **People** view (press **O** in Library) and name face clusters. Only named people get coverage guarantees.

### Cost Tracking

API costs are tracked in real-time across all passes. The summary dialog shows total cost for both scoring and selection phases, broken down by provider/model.

## Settings

Open via **Library > Plug-in Extras > Settings...**

| Setting | Default | Description |
|---------|---------|-------------|
| Provider | Ollama | AI provider: Ollama, Claude, OpenAI, or Gemini |
| Render Size | 512px | Image size sent to AI for scoring and vision passes |
| Burst Threshold | 2 seconds | Window for burst duplicate detection |
| Skip Already Scored | off | Skip photos that already have scores |
| Logging | off | Write detailed logs per run |

Run-specific settings (mode, target count, weights, story preset) are configured in the Score & Select run dialog and persist between runs.

## Viewing Scores

1. In the Library module, select a scored photo
2. In the right panel, find the **Metadata** section
3. Click the metadata dropdown and select **AI Selects**
4. You'll see: Technical Score, Composition Score, Emotion Score, Moment Score, Content, Category, Eye Quality, Narrative Role, Reject, Perceptual Hash, Score Date, Sequence (Story mode), and Story Note (Story mode)

## Troubleshooting

**"No scored photos found"** — Run "Score Only" or "Score & Select" first. The selection pass reads scores from metadata; it doesn't call the AI.

**Scoring is slow** — Try reducing Render Size in Settings. For local models, smaller models score faster. Claude Haiku is the fastest cloud option.

**Story mode falls back to Best Of** — The AI response couldn't be parsed. Check logs for details. This can happen with smaller local models that struggle with structured JSON responses. Claude and Gemini handle it reliably. If a response was truncated, the log will say "TRUNCATED — model hit output token limit."

**Face coverage not working** — Make sure you've used Lightroom's People view and named faces. Only named people get coverage guarantees.

**Log files** — Enable logging in Settings. Logs are written to `~/Desktop/Selects Logs/` and capture per-image scoring details, timing, costs, and errors.

## File Structure

```
AISelects.lrplugin/
  Info.lua                 — Plugin manifest
  MetadataDefinition.lua   — Custom metadata field definitions (11 fields)
  MetadataTagset.lua       — Metadata panel display configuration
  Prefs.lua                — Settings defaults
  Config.lua               — Settings dialog UI
  ScorePhotos.lua          — Pass 1: AI scoring (batch vision)
  SelectPhotos.lua         — Selection pipeline (Best Of + Story v3)
  ScoreAndSelect.lua       — Run dialog + combined scoring + selection
  StoryPresets.lua         — Story mode preset definitions
  AIEngine.lua             — AI engine: prompts, API calls, hashing, face queries, cost tracking
  dkjson.lua               — Bundled JSON library
models.json                — Remote model definitions
```

## License

MIT
