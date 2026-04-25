# Brief: [title]

**Branch:** brief-NNN-slug
**Model:** sonnet
**Parallel-safe:** false
<!-- Concurrency eligibility (brief-034).
     true  — eligible for concurrent dispatch up to THROTTLE when Edit-surface is disjoint from in-flight briefs.
     false — runs alone (default). Unchanged from pre-034 behavior. -->
**Edit-surface:**
  - [path/to/dir/ or glob/*.ext]
<!-- Paths this brief will write to. Read only when Parallel-safe: true.
     - Multi-line list under the field (YAML-style) OR a single comma-separated line.
     - Paths relative to repo root. Trailing / = directory + everything beneath it.
     - Glob * accepted (fnmatch-style). Empty or missing = claims the whole repo.
     - Trust-based in v0: declared at dispatch, not enforced at commit time. -->

## Goal
[What you're trying to accomplish. 1-2 sentences.]

## Budget
<!-- Hive's parser scans this section for integers and uses MAX as the cycle budget,
     so it appears in the active-brief indicator as `cycle X/Y`. Keep this section
     SHORT and only mention the cycle count integer. Do NOT include "~200 LOC", "N=10
     episodes", "3 days", or other non-cycle numbers — they'll be picked up as Y.
     Pattern that works (brief-061): "**6 cycles sonnet.** [one short prose line]." -->
**N cycles.** [Brief plan in prose. No other integers.]

## Tasks
1. [One iteration of work]
2. [One iteration of work]
3. [One iteration of work]

## Completion Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Verification
- Builds clean
- [Project-specific checks]

<!-- AVOID — sections like "what should feel if it lands right" with target-shape
     numerical examples (e.g., "headline reads '38/50 (76.0%, [0.62, 0.86])'").
     Workers pattern-match these as "deliver this content" and paste them into
     review.md TL;DRs as if observed. Soft confabulation, same shape as brief-037's
     visual confab. If you want vivid framing, use shape-only ("the headline reads
     N/M with a Wilson CI") or describe the qualitative outcome ("the arm picks up
     the block"). Numerical examples belong in test fixtures or completion criteria,
     not in target-feel sections. See TROUBLESHOOTING.md (2026-04-25) for the
     brief-055 incident that motivated this warning. -->

