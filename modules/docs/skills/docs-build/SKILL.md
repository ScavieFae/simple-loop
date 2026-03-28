---
name: docs-build
description: Build the docs site — run prebuild, then zensical build
---

# Docs Build

Build the documentation site. This produces a static site from the markdown source.

## Process

1. **Read module config** from `.loop/modules/docs/config.json`
2. **Run prebuild script** if configured:
   - Execute the `prebuild_script` from config
   - This is where generated content (changelogs, API docs, experiment summaries) gets written to the docs directory
3. **Run Zensical build:**
   ```bash
   uvx zensical build -d {docs_dir}
   ```
4. **Report result** — success or failure with error output

## When to use

- Before deploying docs
- After significant content changes
- As part of CI/CD

## Notes

- The build output goes to `{build_dir}` (default: `.loop/modules/docs/state/site/`)
- Build errors are usually broken markdown or bad nav references in `zensical.toml`
- Zensical is compatible with MkDocs Material extensions — if a build fails on an extension, check that it's installed
