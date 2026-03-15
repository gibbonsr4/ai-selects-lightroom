# AI Selects — Project Context

## What This Is

A Lightroom Classic plugin (Lua) that uses AI vision models to score and select photos. Multi-pass architecture: AI scoring → three-layer dedup → story assembly → beat casting → review. Supports Claude, OpenAI, Gemini, and Ollama. macOS only.

## Architecture

```
Score (AI vision) → Reject → Burst Dedup → Phash Dedup → MODE SWITCH:
  ├─ Best Of: Content Dedup → Temporal Distribution → Category Distribution → Face Coverage → Collection
  └─ Story v3:
       Scene Inventory (text AI — clusters photos into WHO+WHEN+WHAT moments)
       → Story Assembly (text AI — plans beats from inventory)
       → Candidate Ranking (text AI — ranks candidates per beat)
       → Beat Casting (vision AI — picks best photo per beat, scarcity-first order)
       → Similarity Gate (phash — catches near-duplicate selections)
       → Story Review (vision AI — coherence check + gap detection)
       → Swap Resolution (vision AI — fixes flagged beats)
       → Face Coverage → Ordered Collection
```

## Key Files

- `AIEngine.lua` — Core AI engine. Scoring prompt, API calls (Ollama, Claude, OpenAI, Gemini), perceptual hashing, face queries, all prompt templates (scoring, scene inventory, story assembly, candidate ranking, beat casting, story review, swap resolution), JSON parsers with `extractJSON` 4-level fallback, partial score recovery. ~3000 lines.
- `SelectPhotos.lua` — Selection pipeline. Both Best Of and Story v3 modes. Shared reject/dedup pipeline, scene inventory, story assembly, scarcity-first beat ordering, image cache, phash similarity gate, face coverage, collection creation. ~2500 lines.
- `ScorePhotos.lua` — Scoring pass. Renders JPEGs, sends to AI, writes metadata, computes perceptual hashes, stop reason detection, partial score recovery from truncated responses. ~770 lines.
- `ScoreAndSelect.lua` — Primary entry point. Run config dialog UI, calls score + select.
- `BatchStrategy.lua` — Provider-specific config (batch sizes, token limits, timeouts). ~290 lines.
- `StoryPresets.lua` — Story mode preset definitions (8 presets).
- `Config.lua` — Settings dialog (provider, model, API key, logging).
- `Prefs.lua` — Default preference values.
- `MetadataDefinition.lua` — 11 custom metadata fields, schemaVersion 4. **Critical: `browsable = true` requires `searchable = true`.**
- `MetadataTagset.lua` — How fields appear in LR's Metadata panel.
- `Info.lua` — Plugin manifest. LrToolkitIdentifier: `com.sonoranstrategy.ai-selects`.
- `dkjson.lua` — Bundled JSON library (do not modify).

## Provider Notes

- **Claude** (Sonnet 4.6): Most reliable, best quality. ~$0.70 for 68 photos (score + select). No special handling needed.
- **Gemini 2.5 Flash**: 21x cheaper (~$0.03 for 68 photos). Requires `thinkingConfig: {thinkingBudget: 0}` to prevent thinking tokens from consuming output budget. Scores ~0.5 points higher than Claude on average (more generous grader). Rank correlation with Claude: ~0.73.
- **OpenAI**: Works, similar cost to Claude.
- **Ollama**: Local models, no cost but lower quality. No anchor images, no snapshots.

## Gemini 2.5 Gotchas

- **Thinking tokens consume maxOutputTokens**: Gemini 2.5 models think by default. Without `thinkingBudget: 0`, a 4096-token limit may produce only ~500 tokens of actual response. We disable thinking for all structured JSON calls.
- **`thinkingBudget: 0` may not always be honored**: Known Gemini API issue. We set generous synthesis token limits (16384) as insurance, and scale token budgets with photo count.
- **Thought parts in response**: Response parts may include `thought: true` entries. We extract the LAST non-thought text part.

## Lightroom SDK Gotchas

- **schemaVersion**: Must increment when metadata fields change. If LR shows "error reading schema", check `~/Library/Application Support/Adobe/Lightroom/lrc_console.log` for the actual error.
- **browsable + searchable**: `browsable = true` silently requires `searchable = true`. The generic error dialog gives no details.
- **No custom sort order via SDK**: Collections support "Custom Order" but there's no API to set it. Photos are added in order; user must select Custom Order sort manually.
- **No Adobe Assisted Culling scores via SDK**: Subject Focus, Eye Focus, Eyes Open are not available.
- **No histogram via SDK**.
- **EXIF data available** via `photo:getRawMetadata()` — ISO, shutter speed, aperture, focal length — but not currently used in scoring.
- **Plugin reload requires LR restart**: Code changes are not picked up until Lightroom Classic is restarted (or plugin is removed and re-added via Plug-in Manager).

## Lua Quirks

- `.` in patterns does NOT match newlines. Use `[\1-\127\128-\255]` for multi-line matching.
- `string.format()` treats `%` as format specifiers. Use `gsub` with `function() return value end` for safe replacement of strings containing special characters (like JSON).
- `ipairs` iterates arrays (sequential numeric keys). `pairs` iterates all keys. `validIds` for story response parsing must be an array, not a set.
- `%b{}` balanced brace matcher is useful for extracting JSON objects from truncated responses.

## Common Operations

- **Score photos**: ScorePhotos.lua renders JPEG via `photo:requestJpegThumbnail()`, base64 encodes, sends to AI, writes scores to plugin metadata. Computes dHash perceptual hash via `sips` BMP conversion.
- **Story mode v3**: Scene inventory clusters photos by WHO+WHEN+WHAT → story assembly plans beats → candidate ranking + beat casting selects photos → review + swap resolution polishes.
- **Face queries**: Reads LR catalog SQLite database directly via `sqlite3` command. Read-only.
- **Perceptual hash**: Renders 9×8 BMP via `sips`, computes dHash (64-bit fingerprint). Handles both 24-bit and 32-bit BMPs (modern macOS sips produces 32-bit).
- **Image cache**: Vision passes (4, 5, 6) pre-render candidate photos once and reuse cached images across beats. Cleaned up at end of pipeline.

## Key Design Decisions

- **Scarcity-first beat ordering**: Pass 4 processes beats with fewest candidates first, preventing pool depletion where later beats find all candidates used.
- **Scene/Moment Inventory**: Pre-pass clusters photos by WHO (people groups) + WHEN (capture time) + WHAT (activity). Duration-adaptive: handles 1-hour sessions to 5-year compilations.
- **extractJSON 4-level fallback**: Direct parse → fence strip → first-{-to-last-} → first-[-to-last-]. Handles markdown fences, surrounding text, and bare arrays.
- **Partial score recovery**: When JSON is truncated, `recoverPartialScores()` extracts individual complete score objects using Lua's `%b{}` matcher.
- **Stop reason tracking**: All providers return stop/finish reason. Truncation is detected and reported clearly instead of cryptic parse errors.
- **Adaptive token budgets**: Scene inventory and story assembly token limits scale with photo count (base + per-photo multiplier).

## Testing

- Score a small batch (3-5 photos) first when testing new providers or after code changes.
- Check logs at `~/Desktop/Selects Logs/`.
- Check LR console at `~/Library/Application Support/Adobe/Lightroom/lrc_console.log` for plugin errors.
- Story mode: if AI response parsing fails, it falls back to Best Of with a warning.
- **Always restart LR after code changes** — the plugin code is cached in memory.
