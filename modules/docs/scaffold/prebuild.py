#!/usr/bin/env python3
"""
Docs prebuild script.

Runs before zensical build to generate or copy content into the docs directory.
Projects customize this to pull in generated content — changelogs, experiment
summaries, API docs, etc.

Usage:
    python prebuild.py [--docs-dir docs]

This script is intentionally minimal. Add your project-specific generators here.
"""

import argparse
import json
import shutil
from pathlib import Path


def load_manifest(state_dir: Path) -> dict:
    """Load the page manifest, or return empty structure."""
    manifest_path = state_dir / "manifest.json"
    if manifest_path.exists():
        return json.loads(manifest_path.read_text())
    return {"pages": [], "nav_sections": []}


def check_staleness(manifest: dict, project_root: Path) -> list[dict]:
    """Return manifest pages whose source files have changed since last generation."""
    stale = []
    for page in manifest.get("pages", []):
        last_gen = page.get("last_generated", "")
        for src in page.get("source_files", []):
            src_path = project_root / src
            if src_path.exists():
                mtime = src_path.stat().st_mtime
                # Simple comparison — ISO timestamp to epoch
                if not last_gen or mtime > _iso_to_epoch(last_gen):
                    stale.append(page)
                    break
    return stale


def _iso_to_epoch(iso_str: str) -> float:
    """Convert ISO 8601 timestamp to epoch seconds."""
    from datetime import datetime, timezone
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return dt.timestamp()
    except (ValueError, AttributeError):
        return 0.0


def main():
    parser = argparse.ArgumentParser(description="Docs prebuild")
    parser.add_argument("--docs-dir", default="docs", help="Docs source directory")
    parser.add_argument("--project-root", default=".", help="Project root")
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    docs_dir = project_root / args.docs_dir
    state_dir = project_root / ".loop" / "modules" / "docs" / "state"

    docs_dir.mkdir(parents=True, exist_ok=True)

    manifest = load_manifest(state_dir)
    stale_pages = check_staleness(manifest, project_root)

    if stale_pages:
        print(f"prebuild: {len(stale_pages)} stale page(s)")
        for page in stale_pages:
            print(f"  - {page['doc_path']} ({page['page_type']})")
    else:
        print("prebuild: all pages up to date")

    # --- Project-specific generators go below ---
    # Example:
    #   copy_changelog(project_root, docs_dir)
    #   generate_experiment_index(project_root, docs_dir)


if __name__ == "__main__":
    main()
