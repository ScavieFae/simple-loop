# Hand-merging a brief when the daemon can't

A legitimate, repeatable pattern — not an edge case. Use when the daemon is in a state-mismatch, keychain-locked (daemon can't push), or otherwise stuck and you need to land a branch cleanly.

## The recipe

```bash
# 1. Kill the daemon cleanly
loop stop

# 2. Commit any loose state files on the brief's branch
git add .loop/state/
git commit -m "[scav] commit loose state files before hand-merge"

# 3. Smoke-check
git status                 # confirm clean
# run project verification if applicable

# 4. Merge with --no-ff (keeps the branch visible in history)
git checkout main
git merge --no-ff brief-NNN-slug -m "[scav] Merge brief-NNN-slug: <title>"

# 5. Clean up
git branch -d brief-NNN-slug
git worktree remove .loop/worktrees/brief-NNN-slug
rm -f .loop/state/pending-merge.json
```

## When to use it

- Daemon is in a state-mismatch (parse bugs in the loop itself, or v1/v2 schema divergence).
- Push credentials failed (see [daemon-push-auth.md](daemon-push-auth.md)) and you can't wait for the fix.
- Validator approved, eval is clean, you want to unblock now.

## When NOT to use it

- Brief didn't pass the validator yet — hand-merge bypasses the completion check.
- The branch is mid-cycle (not at a completion point) — merge what's there and you'll have a partial artifact on main.
- Auto-merge is working fine — no reason to touch it.

## Signal cleanup

After a hand-merge, the daemon's state files may still reference the brief. Check:

```bash
cat .loop/state/running.json   # should show no active brief, or the next one
ls .loop/state/signals/        # remove any stale escalate.json for the merged brief
```

Restart with `loop start` if the daemon was stopped.
