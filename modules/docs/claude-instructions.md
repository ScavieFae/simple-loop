<!-- simple-loop:docs -->

## Docs Module

This project has the simple-loop docs module installed. It produces a living documentation site from project markdown using Zensical (Material for MkDocs-compatible static site generator).

### How it works

Markdown files in the docs directory are the source of truth. Agents write markdown, the module builds a static site. A manifest tracks which source files map to which doc pages, enabling change-driven regeneration.

### Key files

- `zensical.toml` — site config (theme, nav, extensions). Lives in project root.
- `docs/` — markdown source files (or whatever `docs_dir` is configured to)
- `.loop/modules/docs/state/manifest.json` — page manifest (source file → doc page mapping)
- `.loop/modules/docs/state/build-log.jsonl` — build history
- `.loop/modules/docs/config.json` — module config

### Writing docs

Any agent can write to the docs directory. Follow these conventions:
- One concept per page
- Use Mermaid fenced code blocks for diagrams
- Include source file paths so readers can find the code
- Use admonitions (`!!! note`, `!!! warning`) for callouts
- Update the manifest when adding or removing pages

### Building

Use the `docs-build` skill or run directly:
```bash
uvx zensical build
```

### Serving locally

Use the `docs-serve` skill or run directly:
```bash
uvx zensical serve --dev-addr 0.0.0.0:8000
```

### Manifest-driven regeneration

The manifest (`manifest.json`) maps each doc page to its source files. When an agent updates source files, it can check the manifest to see which doc pages are affected and regenerate only those. This is the "file-relevance as metadata" pattern — each doc page declares what it's about.

<!-- /simple-loop:docs -->
