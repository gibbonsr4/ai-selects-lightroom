# AI Selects — Roadmap

The goal: turn a camera roll into a finished product. A professional photographer shoots 3,000 wedding photos and needs 150 for delivery — they'll get there eventually, but it takes hours. A parent shoots 800 vacation photos and wants a 40-photo book — they'll never get there without help. AI Selects gives both of them a collection they can use as-is or with minimal tweaks.

Existing culling tools handle the obvious rejects (thousands → hundreds). AI Selects handles everything after that — scoring, deduplication, narrative curation, and final selection — delivering a ready-to-use edit.

Everything on this roadmap serves that goal: make the output good enough to use directly.

Updated 2026-03-12.

---

## What's Built

### Scoring
- Vision AI scoring via Claude API or local Ollama models
- Technical (1-10), aesthetic (1-10), content description, category, narrative role, eye quality, reject flag
- Composite score with configurable quality/aesthetic weights and eye quality adjustments
- Skip-already-scored for incremental workflows

### Selection — Best Of
- Quality-driven culling with temporal distribution across the timeline
- Category-aware proportional distribution
- Face coverage — every named person appears at least once

### Selection — Story Mode
- 8 genre presets (Family Vacation, Documentary Travel, Wedding, Portrait Session, Editorial, Landscape Portfolio, Fun/Playful, Custom)
- Text-only metadata summary sent to AI (no images — fast and cheap)
- Custom instructions field appends to any preset
- Gap detection and filling for missing people, narrative roles, timeline coverage
- Sequence numbering for story ordering
- Fallback to Best Of if AI response fails

### Pipeline
- Burst dedup (EXIF timestamps) and visual dedup (perceptual hashing via dHash)
- Face detection via Lightroom's catalog database (read-only)
- Non-destructive output — creates Collections, never modifies originals
- Auto-navigation to new collection after creation
- Run dialog for per-session config, separate Settings for provider/model setup
- Progress bar with step captions
- Zero external dependencies — macOS built-in tools only (sips, sqlite3, curl)

---

## Up Next

### Fix Perceptual Hashing
The sips BMP pipeline produces parse warnings on many images, making visual dedup non-functional (falls back to burst dedup only). This directly impacts selection quality — near-duplicates slip through into the final set. Investigate alternative image format or hashing approach.

### Gap Fill Transparency
When the tool pulls in a weaker photo to fill a narrative gap (missing person, missing role), the user should know why it's there. Use the existing `aiSelectsStoryNote` metadata field — gap fills get a note like "Gap fill: ensures Sarah appears in the edit." The info is visible in the AI Selects metadata panel when you inspect the photo, but doesn't touch color labels, star ratings, or anything else catalog-wide.

### Alternates Collection (Opt-In)
Optional feature, off by default — a checkbox in the run dialog. When enabled, creates a second collection alongside the primary edit containing the next-best runners-up. Users can compare in Survey mode and swap between collections using familiar LR workflows. No custom UI needed.

### People Balancing
Face coverage currently guarantees presence (at least one photo per named person) but not balance. A wedding album where the bride appears 30 times and the groom 5 times is a bad deliverable. Add proportional representation logic that distributes selections more evenly across named people, weighted by their frequency in the source set.

### Additional AI Providers
Add OpenAI (GPT-4V) and Google Gemini as cloud provider options alongside Claude. Cloud vision models are significantly better than most local models at scoring — faster and more accurate. Photographers will have preferences or existing API keys. The scoring prompt and response parsing are provider-agnostic; this is primarily a new API transport layer per provider.

### Scoring Speed
Scoring is the bottleneck. 500 photos scored one-by-one takes a long time. Investigate:
- Parallel requests (multiple concurrent API calls)
- Batch scoring (multiple images per call where the API supports it)
- Smarter skip logic (hash-based change detection to avoid re-scoring unchanged photos)

---

## Future Considerations

Ideas worth exploring once the core is solid:

- **Score quality tuning** — prompt refinements, model-specific calibration, per-category scoring adjustments
- **Story mode improvements** — better handling of very large photo sets (1000+), two-pass narrative refinement, preset-specific scoring weight overrides
- **Smart Preview scoring** — score from Smart Previews when originals are offline
- **Collection sets** — organize AI Selects output collections into a collection set for cleaner catalog management
- **Category normalization** — tighten the scoring prompt to return consistent categories, or normalize in post-processing
