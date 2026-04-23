# Daemon push auth — macOS keychain lock recipe

## The problem

On macOS, `git push` inside a daemon process fails silently after the machine sleeps and locks the keychain. The daemon sees a non-zero exit code and logs a warning, but the merge commit never reaches the remote. Nothing explodes visibly — you just notice the remote is behind local.

## Fix (run once per machine)

```bash
gh auth setup-git
```

This configures git's credential helper to use `gh`'s stored OAuth token, which survives keychain locks indefinitely. No env vars to manage, no manual token rotation.

Verify it worked:

```bash
git credential approve <<EOF
protocol=https
host=github.com
EOF
```

(No prompt means the helper is registered.)

## Tighten scopes (optional)

If you want to limit what the token can do:

```bash
gh auth refresh --hostname github.com --remove-scopes workflow
```

Interactive — opens a browser window. Removes the `workflow` scope if you don't need Actions write access. Scopes currently on your token: `gh auth status`.

## Related

- `loop init` prerequisite check surfaces this on new machines.
- The same incident that surfaced this also surfaced the process-alive ≠ loop-healthy pattern. Heartbeat checking (via `loop status`) was the fix for the health-check piece; this doc covers the push-cred piece.
