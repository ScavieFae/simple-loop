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
