# AI Selects — Roadmap

The goal: turn a camera roll into a finished product. A professional photographer shoots 3,000 wedding photos and needs 150 for delivery — they'll get there eventually, but it takes hours. A parent shoots 800 vacation photos and wants a 40-photo book — they'll never get there without help. AI Selects gives both of them a collection they can use as-is or with minimal tweaks.

Existing culling tools handle the obvious rejects (thousands → hundreds). AI Selects handles everything after that — scoring, deduplication, narrative curation, and final selection — delivering a ready-to-use edit.

Everything on this roadmap serves that goal: make the output good enough to use directly.

Updated 2026-03-14.

---

## What's Built

### Scoring (Pass 1)
- Vision AI scoring via Claude, OpenAI, Gemini, or local Ollama models
- Four scoring dimensions: technical (1-10), composition (1-10), emotion (1-10), moment (1-10)
- Content description, category, narrative role, eye quality, reject flag
- Batch scoring with relative ranking across photos
- Composite score with configurable technical/aesthetic weights and eye quality adjustments
- Perceptual hash (dHash) computed per photo for visual dedup
- Skip-already-scored for incremental workflows
- Pre-scoring hints for user context ("this is from 2007", "the older man is my dad")
- Real-time API cost tracking per batch and cumulative

### Selection — Best Of
- Quality-driven culling with temporal distribution across the timeline
- Category-aware proportional distribution
- Face coverage — every named person appears at least once

### Selection — Story Mode (v3 Multi-Pass Pipeline)
- Mid-run story dialog with AI-prepopulated summary, editable story prompt, emphasis field, and adjustable target count
- 8 genre presets (Family Vacation, Documentary Travel, Wedding, Portrait Session, Editorial, Landscape Portfolio, Fun/Playful, Custom)
- Pass 2: Story Assembly — text-only AI call generates beat list from metadata
- Pass 3A: Code pre-filter — hard constraints per beat (time window, category, people)
- Pass 3B: AI text ranking — orders candidates by narrative fit
- Pass 4: Beat Casting — vision-based per-beat selection (cloud providers)
- Pass 5: Story Review — vision review of full selection for coherence
- Pass 6: Swap Resolution — targeted vision comparisons for flagged positions
- Fallback to Best Of if story pipeline fails

### Deduplication (Three Layers)
- Burst dedup via EXIF timestamps (configurable threshold)
- Perceptual hashing via dHash (9×8 BMP, 64-bit fingerprint, Hamming distance)
- Content description similarity (word overlap + time window)

### Infrastructure
- Face detection via Lightroom's catalog database (read-only SQLite queries)
- Image cache for vision passes — renders once, reused across Passes 4-6
- API cost tracking with per-model pricing for Claude, OpenAI, Gemini
- Non-destructive output — creates Collections, never modifies originals
- Auto-navigation to new collection after creation
- Progress bar with per-pass captions
- Zero external dependencies — macOS built-in tools only (sips, sqlite3, curl)

---

## Up Next

### Scene Inventory Pass (#9)
**The biggest quality issue.** Story mode selections frequently include thematically duplicate content (e.g., multiple similar group shots) while missing distinct scenes that should be represented. No single pass currently has a birds-eye view of the full visual set.

**Solution:** Add a scene clustering pass before story arc generation. Send all content descriptions + timestamps to the AI in a single text call to produce a scene inventory ("4 dinner scenes, 12 ceremony shots, 3 candids by the pool"). Feed this to the story assembly pass so it selects across clusters, ensuring coverage and avoiding redundancy.

### Standalone Select Story Support (#3)
When running Select separately (after scoring), there's no mid-run story dialog — falls back to v2 path. Need to add the story dialog with prepopulation from catalog metadata.

### Snapshot Persistence (#4)
Batch snapshots (scene descriptions from scoring) exist only in memory. Standalone Select gets no snapshots, degrading story assembly quality. Options: persist to metadata field (requires schemaVersion bump) or accept the fallback.

### Cumulative Batch Context (#5)
Pass prior batch snapshots to subsequent scoring batches so the AI builds cumulative context of the shoot. Also: confirm chronological sort order, flag continuity issues.

### End-to-End Testing (#8)
Passes 4-6 (Beat Casting, Story Review, Swap Resolution) need end-to-end testing against real photo sets.

---

## Future Considerations

Ideas worth exploring once the core is solid:

- **Score quality tuning** — prompt refinements, model-specific calibration, per-category scoring adjustments
- **Third scoring dimension** — interest/impact/story relevance as a distinct axis (#2)
- **People balancing** — proportional representation across named people, not just presence
- **Alternates collection** — optional second collection with runners-up for easy comparison
- **Smart Preview scoring** — score from Smart Previews when originals are offline
- **Collection sets** — organize AI Selects output collections into a collection set
- **Parallel API requests** — concurrent scoring calls for speed
