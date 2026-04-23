# Brief cards

Each brief lives in its own directory: `wiki/briefs/cards/brief-NNN-slug/`. The card collects all artifacts for one brief — it's both an organizational pattern and an observability surface.

## Card anatomy

| File | Purpose | Required |
|------|---------|---------|
| `index.md` | The brief itself (the assignment) | Yes |
| `plan.md` | Implementation plan written by worker | Optional |
| `closeout.md` | Summary written at completion | Expected |
| `evaluation.md` | Validator review | Written by reviewer agent |

## Naming

`brief-NNN-slug` — three-digit zero-padded number, descriptive kebab-case slug. Numbers are sequential across the project; slugs must be unique.

Examples: `brief-014-simple-loop-hardening`, `brief-026-simple-loop-bundle-portability`

## Symlink convention

Brief files in `.loop/briefs/` are symlinks into the card directory:

```bash
ln -s ../../wiki/briefs/cards/brief-NNN-slug/index.md .loop/briefs/brief-NNN-slug.md
```

The daemon reads `.loop/briefs/` directly; the symlink means the daemon dispatch path is stable while the canonical source stays in the wiki.

## The observability benefit

When a brief is done, the card directory contains the full record: the assignment, the plan, what actually happened in each cycle (via `git log` on that branch), and the closeout. Pulling the card is the fastest path to understanding a past decision.

## Adding a brief

1. `mkdir wiki/briefs/cards/brief-NNN-slug/`
2. Write `wiki/briefs/cards/brief-NNN-slug/index.md`
3. `ln -s ../../wiki/briefs/cards/brief-NNN-slug/index.md .loop/briefs/brief-NNN-slug.md`
4. Add to `goals.md` under `## Queued next`
