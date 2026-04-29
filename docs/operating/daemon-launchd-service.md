# Daemon LaunchAgent service

The simple-loop daemon can run as a macOS LaunchAgent — owned by `launchd` rather than your shell. This means it survives SSH disconnects, terminal closes, and machine reboots without ceremony.

## Why

`loop start &` (the default) parents the daemon to your shell. When the shell exits — SSH disconnect, terminal close, `exit` — the kernel sends SIGHUP down the process tree and the daemon dies. `disown -h` or `tmux` are workarounds; they're not solutions.

LaunchAgent ownership moves the parent from your shell to `launchd`. launchd lives for the lifetime of your login session. The daemon outlives any terminal that launched it, restarts automatically on crash, and comes back after a reboot.

## Quick start

```bash
# One-time per machine, per project
loop install-service

# Verify
launchctl list | grep simpleloop
loop logs -f
```

That's it. `loop start` / `loop stop` continue to work — they route through launchctl when the LaunchAgent is installed.

## How it works

`loop install-service` does three things:

1. **Interpolates the plist template** (`templates/com.scaviefae.simpleloop.plist`) with your project-specific values: project name, project dir, lib dir, interval, log path, HOME, PATH.
2. **Copies the plist** to `~/Library/LaunchAgents/com.scaviefae.simpleloop.<project>.plist`.
3. **Loads it** via `launchctl load -w`. The `-w` flag clears the `Disabled` flag, so the agent starts immediately and persists across reboots.

The label pattern `com.scaviefae.simpleloop.<project>` means multiple projects can coexist on one machine — each gets its own LaunchAgent.

### Plist highlights

| Key | Value | Why |
|-----|-------|-----|
| `RunAtLoad` | `true` | Auto-start on login |
| `KeepAlive.SuccessfulExit` | `false` | Restart on crash; stop on clean `loop stop` |
| `ThrottleInterval` | 30 | Don't restart faster than every 30s after a crash |
| `StandardOutPath` / `StandardErrorPath` | `.loop/logs/daemon.log` | Same log path as the old `&`-backgrounded path |

## Commands

```bash
loop install-service [interval]   # Install LaunchAgent (default interval: HEARTBEAT_INTERVAL or 300s)
loop uninstall-service            # Unload and remove the LaunchAgent
loop start                        # Start daemon (routes via launchctl if LaunchAgent installed)
loop stop                         # Stop daemon (routes via launchctl if LaunchAgent installed)
```

`install-service` is idempotent — safe to re-run if you change the interval or after updating simple-loop.

## Migration from bare-background mode

If you've been running `loop start` without the LaunchAgent:

```bash
loop stop                  # Kill the old background daemon
loop install-service       # Install the LaunchAgent and start the daemon
```

## Multi-project pattern

Each project root gets its own LaunchAgent:

```bash
cd ~/code/portal && loop install-service
cd ~/code/nt-rnd && loop install-service

launchctl list | grep simpleloop
# com.scaviefae.simpleloop.portal
# com.scaviefae.simpleloop.nt-rnd
```

They run independently. `loop stop` in the portal directory only stops the portal agent.

## Troubleshooting

### Check agent status

```bash
launchctl list | grep simpleloop
# Shows: PID, last-exit-status, label
# PID present = running
# PID 0 / missing = stopped or never started
```

### Read logs

```bash
loop logs -f                                        # Live tail
cat .loop/logs/daemon.log                           # Full log
```

launchd also captures stdout/stderr to the log paths in the plist — same file.

### Check launchd's own error log

If `launchctl load` succeeds but the daemon never starts, launchd may have rejected it:

```bash
log show --predicate 'process == "launchd"' --last 5m | grep simpleloop
```

Common causes: wrong path in `ProgramArguments`, missing executable permissions on `daemon.sh`, or `WorkingDirectory` doesn't exist.

### Disable temporarily (without uninstalling)

```bash
launchctl unload ~/Library/LaunchAgents/com.scaviefae.simpleloop.<project>.plist
```

This stops the daemon and prevents it from auto-starting on next login (sets the `Disabled` flag). Re-enable with:

```bash
launchctl load -w ~/Library/LaunchAgents/com.scaviefae.simpleloop.<project>.plist
```

Or just run `loop start` — it uses `-w` to clear the Disabled flag.

### Re-install after simple-loop update

```bash
cd ~/claude-projects/simple-loop
git pull && ./install.sh
cd /path/to/your/project
loop stop
loop install-service    # Rewrites plist with updated paths
```

### Agent loaded but daemon exits immediately

Check the last exit status via `launchctl list | grep simpleloop`. A non-zero status means the daemon script itself failed. Read the log:

```bash
tail -50 .loop/logs/daemon.log
```

Common causes: missing `.loop/` directory, `config.sh` parse error, Python not in PATH.

If PATH is the issue, the plist's `EnvironmentVariables` captures your PATH at install time. If you later change your PATH (e.g. added a new tool), re-run `loop install-service` to update the plist.

## Verifying crash-restart (manual smoke)

launchd restarts the daemon on crash within `ThrottleInterval` (30s). To verify:

```bash
# 1. Find the daemon PID
launchctl list | grep simpleloop     # read PID column
# or: cat .loop/state/running.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid',''))"

# 2. Kill it
kill <pid>

# 3. Wait ~35 seconds, then check
launchctl list | grep simpleloop     # new PID should appear
loop logs -f                         # daemon restart logged
```

For a scripted version, see `scripts/test-launchd-restart.sh`.

## What `loop stop` does (LaunchAgent path)

`launchctl unload` (no `-w`) stops the daemon and resets the `Disabled` flag to cleared — meaning the agent will still auto-start on next login. The LaunchAgent remains installed. This matches "stop for now, restart later" semantics.

To prevent auto-start on next login, use `launchctl unload` directly (which sets `Disabled`), or run `loop uninstall-service`.
