# AI Selects — Project Context

## What This Is

A Lightroom Classic plugin (Lua) that uses AI vision models to score and select photos. Two-pass architecture: AI scoring → algorithmic/AI selection. macOS only.

## Architecture

```
Score (AI vision) → Reject → Burst Dedup → Phash Dedup → MODE SWITCH:
  ├─ Best Of: Temporal Distribution → Category Distribution → Face Coverage → Collection
  └─ Story:  Metadata Summary → AI Text Call → Gap Detection → Face Coverage → Ordered Collection
```

## Key Files

- `AIEngine.lua` — Core AI engine. Scoring prompt, API calls (Ollama + Claude), perceptual hashing, face queries, story prompt template, response parsers. ~950 lines.
- `SelectPhotos.lua` — Selection pipeline. Both Best Of and Story modes. Shared reject/dedup pipeline, mode dispatch, face coverage, collection creation. ~930 lines.
- `ScorePhotos.lua` — Scoring pass. Renders JPEGs, sends to AI, writes metadata.
- `ScoreAndSelect.lua` — Primary entry point. Run config dialog UI, calls score + select.
- `StoryPresets.lua` — Story mode preset definitions (8 presets).
- `Config.lua` — Settings dialog (provider, model, API key, logging).
- `Prefs.lua` — Default preference values.
- `MetadataDefinition.lua` — 11 custom metadata fields, schemaVersion 4. **Critical: `browsable = true` requires `searchable = true`.**
- `MetadataTagset.lua` — How fields appear in LR's Metadata panel.
- `Info.lua` — Plugin manifest. LrToolkitIdentifier: `com.sonoranstrategy.ai-selects`.
- `dkjson.lua` — Bundled JSON library (do not modify).

## Lightroom SDK Gotchas

- **schemaVersion**: Must increment when metadata fields change. If LR shows "error reading schema", check `~/Library/Application Support/Adobe/Lightroom/lrc_console.log` for the actual error.
- **browsable + searchable**: `browsable = true` silently requires `searchable = true`. The generic error dialog gives no details.
- **No custom sort order via SDK**: Collections support "Custom Order" but there's no API to set it. Photos are added in order; user must select Custom Order sort manually.
- **No Adobe Assisted Culling scores via SDK**: Subject Focus, Eye Focus, Eyes Open are not available.
- **No histogram via SDK**.
- **EXIF data available** via `photo:getRawMetadata()` — ISO, shutter speed, aperture, focal length — but not currently used in scoring.

## Lua Quirks

- `.` in patterns does NOT match newlines. Use `[\1-\127\128-\255]` for multi-line matching.
- `string.format()` treats `%` as format specifiers. Use `gsub` with `function() return value end` for safe replacement of strings containing special characters (like JSON).
- `ipairs` iterates arrays (sequential numeric keys). `pairs` iterates all keys. `validIds` for story response parsing must be an array, not a set.

## Common Operations

- **Score photos**: ScorePhotos.lua renders JPEG via `photo:requestJpegThumbnail()`, base64 encodes, sends to AI, writes scores to plugin metadata.
- **Story mode**: Builds JSON metadata summary (no images), sends text-only API call, parses ordered response, writes sequence numbers to metadata.
- **Face queries**: Reads LR catalog SQLite database directly via `sqlite3` command. Read-only.
- **Perceptual hash**: Renders 9×8 BMP via `sips`, computes dHash. Currently failing on all photos due to sips BMP format issue (non-blocking — hash is skipped).

## Testing

- Score a small batch (10-20 photos) first.
- Check logs at `~/Desktop/Selects Logs/`.
- Check LR console at `~/Library/Application Support/Adobe/Lightroom/lrc_console.log` for plugin errors.
- Story mode: if AI response parsing fails, it falls back to Best Of with a warning.
