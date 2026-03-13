# AI Selects — Lightroom Classic Plugin

AI-powered photo culling for Lightroom Classic. Score hundreds of photos using vision AI models, then select the best subset using quality-driven culling or AI-driven narrative storytelling.

**The problem:** Photographers routinely shoot 500+ photos per session but need 40-80 for a final deliverable. Existing culling tools handle the "thousands to hundreds" first pass (removing obvious rejects), but the "hundreds to dozens" final selection remains entirely manual. AI Selects automates this second pass using vision LLMs for scoring, combined with smart deduplication, category-aware distribution, and optional AI narrative curation.

## Features

- **Two selection modes:**
  - **Best Of** — quality-driven culling with temporal distribution across your timeline
  - **Story** — AI-driven narrative selection with genre presets and gap detection
- **AI scoring** via Claude API or local Ollama models — rates technical quality, aesthetic appeal, content, narrative role, and eye quality
- **Smart deduplication** — removes burst duplicates (EXIF timestamps) and visually similar shots (perceptual hashing)
- **Category-aware selection** — groups photos by content type (landscape, portrait, street, etc.) and distributes selections proportionally or equally
- **Face coverage** — automatically ensures at least one photo of every named person is included, using Lightroom's built-in face detection data
- **Story presets** — Wedding, Family Vacation, Documentary Travel, Portrait Session, Editorial, Landscape Portfolio, Fun/Playful, and Custom
- **Eye quality scoring** — detects and penalizes closed/squinting eyes, rewards sharp engaged eyes
- **Non-destructive** — creates a Collection with your selects; never modifies or deletes originals
- **Zero external dependencies** — uses macOS built-in tools (`sips`, `sqlite3`, `curl`) for all processing

## Requirements

- macOS (uses `sips`, `sqlite3`, and `curl` which are built-in)
- Lightroom Classic (SDK 6.0+)
- One of:
  - **Ollama** installed locally with a vision model (free, private, no API key needed)
  - **Anthropic API key** for Claude (fast, high quality, pay-per-use)

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
5. Your selects appear in a new Collection and Lightroom navigates to it automatically

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
- **Additional instructions** — free-text field appended to any preset
- **Target count** — how many photos to select
- **Quality / Aesthetic weights** — balance technical vs. aesthetic scoring
- **Provider info** — shows current AI provider (change in Settings)

### Selection Modes

#### Best Of

Quality-driven culling with temporal distribution. Ensures selections are spread across your timeline, preventing clustering around a single time period.

Pipeline: Reject → Burst Dedup → Visual Dedup → Temporal Segmentation → Category Distribution → Face Coverage → Collection

#### Story

AI-driven narrative selection. Sends a metadata-only summary (no images) to the AI, which returns an ordered selection with editorial notes. Includes gap detection for missing people, narrative roles, and timeline coverage.

Pipeline: Reject → Burst Dedup → Visual Dedup → Build Metadata Summary → AI Narrative Call → Gap Detection → Face Coverage → Ordered Collection

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
| Custom | User-defined via additional instructions field | Yes | Medium |

In Story mode, set sort order to **Custom Order** in the toolbar to view photos in narrative sequence.

## AI Scoring

Each photo is rendered as a JPEG, base64-encoded, and sent to the AI model. The AI returns:

| Field | Description |
|-------|-------------|
| **Technical** (1-10) | Sharpness, exposure, noise, white balance |
| **Aesthetic** (1-10) | Composition, lighting, mood, visual impact |
| **Content** | 3-5 word description of the subject/scene |
| **Category** | Primary visual element (landscape, portrait, wildlife, architecture, food, street) |
| **Narrative Role** | Editorial role (scene_setter, character_moment, action, detail, transition, closing, establishing, emotional_peak) |
| **Eye Quality** | Eye quality for visible people (good, fair, closed, na) |
| **Reject** | true if obviously bad (blurry, badly exposed, accidental shot) |

Scores are stored in Lightroom's custom metadata — visible in the Metadata panel under the "AI Selects" tagset.

### Composite Score

Photos are ranked by a weighted composite score with eye quality adjustments:

```
compositeScore = technical * qualityWeight + aesthetic * aestheticWeight + eyeAdjustment
```

Eye adjustments: good eyes +0.5, fair eyes +0, closed eyes -1.5.

With default weights (0.4 / 0.6), a technically perfect but boring photo scores lower than a slightly imperfect but visually stunning one.

## How It Works

### Perceptual Hashing (Duplicate Detection)

AI Selects uses **dHash** (difference hash) to detect visually similar images:

1. Resize the image to 9×8 pixels using macOS `sips`
2. Convert to grayscale
3. Compare adjacent pixels to produce 64 bits
4. Compare hashes via Hamming distance — under 10 bits different = visually similar

This catches duplicates that timestamp-based burst detection misses: returning to the same scene later, multiple compositions of the same subject, near-identical framings.

### Face Detection & Coverage

Uses Lightroom's built-in face detection to ensure every named person appears at least once in the final selects:

1. Queries the catalog database (read-only) for face detection data
2. After selection runs, checks which named people are missing
3. Adds the highest-scoring photo of each missing person

**Setup:** Use Lightroom's **People** view (press **O** in Library) and name face clusters. Only named people get coverage guarantees.

### Story Mode AI Call

Story mode sends a text-only metadata summary to the AI — no images. The summary includes each photo's scores, content description, category, narrative role, eye quality, timestamp, and detected people. The AI returns an ordered selection with position numbers and editorial notes.

If the AI response can't be parsed after one retry, Story mode falls back to Best Of with a warning.

## Settings

Open via **Library > Plug-in Extras > Settings...**

| Setting | Default | Description |
|---------|---------|-------------|
| Provider | Ollama | AI provider: Ollama (local) or Claude (cloud) |
| Render Size | 512px | Image size sent to AI for scoring |
| Burst Threshold | 2 seconds | Window for burst duplicate detection |
| Skip Already Scored | off | Skip photos that already have scores |
| Logging | off | Write detailed logs per scoring run |

Run-specific settings (mode, target count, weights, story preset) are configured in the Score & Select run dialog and persist between runs.

## Viewing Scores

1. In the Library module, select a scored photo
2. In the right panel, find the **Metadata** section
3. Click the metadata dropdown and select **AI Selects**
4. You'll see: Technical Score, Aesthetic Score, Content, Category, Eye Quality, Narrative Role, Reject, Perceptual Hash, Score Date, Sequence (Story mode), and Story Note (Story mode)

## Troubleshooting

**"No scored photos found"** — Run "Score Only" or "Score & Select" first. The selection pass reads scores from metadata; it doesn't call the AI.

**Scoring is slow** — Try reducing Render Size to 512px. For local models, smaller models like Gemma 3 4B score faster. Claude Haiku is the fastest cloud option.

**Story mode falls back to Best Of** — The AI response couldn't be parsed. Check logs for details. This can happen with smaller local models that struggle with the structured JSON response format. Claude models handle it reliably.

**Face coverage not working** — Make sure you've used Lightroom's People view and named faces. Only named people get coverage guarantees.

**"Phash warning: BMP parse failed"** — Non-blocking. The perceptual hash is skipped for affected photos. Duplicate detection still works via timestamp-based burst detection.

**Log files** — Enable logging in Settings. Logs are written to `~/Desktop/Selects Logs/` and capture per-image scoring details, timing, and errors.

## File Structure

```
AISelects.lrplugin/
  Info.lua                 — Plugin manifest
  MetadataDefinition.lua   — Custom metadata field definitions (11 fields)
  MetadataTagset.lua       — Metadata panel display configuration
  Prefs.lua                — Settings defaults
  Config.lua               — Settings dialog UI
  ScorePhotos.lua          — Pass 1: AI scoring
  SelectPhotos.lua         — Pass 2: selection (Best Of + Story modes)
  ScoreAndSelect.lua       — Run dialog + combined Pass 1 + Pass 2
  StoryPresets.lua          — Story mode preset definitions
  AIEngine.lua             — Inference engine, hashing, face queries, text-only API
  dkjson.lua               — Bundled JSON library
models.json                — Remote model definitions
```

## Roadmap

See [ROADMAP.md](ROADMAP.md) for the full feature status and future plans.

## License

MIT
