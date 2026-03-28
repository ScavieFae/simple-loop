---
name: docs-serve
description: Start the Zensical dev server with live reload
---

# Docs Serve

Start a local development server for the documentation site with live reload.

## Process

1. **Read module config** from `.loop/modules/docs/config.json`
2. **Run prebuild script** if configured
3. **Start Zensical dev server:**
   ```bash
   uvx zensical serve -d {docs_dir} --dev-addr 0.0.0.0:{serve_port}
   ```
4. **Report the URL** — `http://localhost:{serve_port}`

## Notes

- The dev server watches for file changes and rebuilds incrementally
- Use `--dev-addr 0.0.0.0:{port}` to make it accessible from other machines (e.g., over Tailscale)
- Kill the server with Ctrl+C or by stopping the background process
