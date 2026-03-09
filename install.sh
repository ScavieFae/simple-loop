#!/bin/bash
# Simple Loop installer
#
# Copies lib/, core/, modules/, and templates/ to ~/.local/share/simple-loop/
# Symlinks bin/loop to ~/.local/bin/loop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${SIMPLE_LOOP_HOME:-$HOME/.local/share/simple-loop}"
BIN_DIR="$HOME/.local/bin"

echo ""
echo "Installing Simple Loop v0.2..."
echo "  Source:  $SCRIPT_DIR"
echo "  Install: $INSTALL_DIR"
echo "  Binary:  $BIN_DIR/loop"
echo ""

# Create directories
mkdir -p "$INSTALL_DIR"/{lib,templates/prompts,templates/agents}
mkdir -p "$INSTALL_DIR"/core/{agents,skills,templates}
mkdir -p "$BIN_DIR"

# Copy lib (daemon runtime)
cp "$SCRIPT_DIR/lib/daemon.sh" "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/lib/actions.py" "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/lib/assess.py" "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/lib/metrics-report.py" "$INSTALL_DIR/lib/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/lib/daemon.sh"

# Copy v1 templates (backward compat)
cp "$SCRIPT_DIR/templates/config.sh" "$INSTALL_DIR/templates/"
cp "$SCRIPT_DIR/templates/brief-template.md" "$INSTALL_DIR/templates/"
cp "$SCRIPT_DIR/templates/prompts/"*.md "$INSTALL_DIR/templates/prompts/"
cp "$SCRIPT_DIR/templates/agents/"*.md "$INSTALL_DIR/templates/agents/"

# Copy v2 core
if [ -d "$SCRIPT_DIR/core" ]; then
    # Core agents
    cp "$SCRIPT_DIR/core/agents/"*.md "$INSTALL_DIR/core/agents/" 2>/dev/null || true

    # Core skills (preserve directory structure)
    if [ -d "$SCRIPT_DIR/core/skills" ]; then
        for skill_dir in "$SCRIPT_DIR/core/skills"/*/; do
            [ -d "$skill_dir" ] || continue
            local_name=$(basename "$skill_dir")
            mkdir -p "$INSTALL_DIR/core/skills/$local_name"
            cp "$skill_dir"* "$INSTALL_DIR/core/skills/$local_name/" 2>/dev/null || true
        done
    fi

    # Core templates
    cp "$SCRIPT_DIR/core/templates/"* "$INSTALL_DIR/core/templates/" 2>/dev/null || true
fi

# Copy v2 modules
if [ -d "$SCRIPT_DIR/modules" ]; then
    for module_dir in "$SCRIPT_DIR/modules"/*/; do
        [ -d "$module_dir" ] || continue
        module_name=$(basename "$module_dir")
        echo "  Module: $module_name"

        # Recreate module structure
        mkdir -p "$INSTALL_DIR/modules/$module_name"

        # Copy module.json
        cp "$module_dir/module.json" "$INSTALL_DIR/modules/$module_name/" 2>/dev/null || true

        # Copy agents
        if [ -d "$module_dir/agents" ]; then
            mkdir -p "$INSTALL_DIR/modules/$module_name/agents"
            cp "$module_dir/agents/"*.md "$INSTALL_DIR/modules/$module_name/agents/" 2>/dev/null || true
        fi

        # Copy skills (preserve directory structure)
        if [ -d "$module_dir/skills" ]; then
            for skill_dir in "$module_dir/skills"/*/; do
                [ -d "$skill_dir" ] || continue
                skill_name=$(basename "$skill_dir")
                mkdir -p "$INSTALL_DIR/modules/$module_name/skills/$skill_name"
                cp "$skill_dir"* "$INSTALL_DIR/modules/$module_name/skills/$skill_name/" 2>/dev/null || true
            done
        fi

        # Copy state schema
        if [ -d "$module_dir/state" ]; then
            mkdir -p "$INSTALL_DIR/modules/$module_name/state"
            cp "$module_dir/state/"*.json "$INSTALL_DIR/modules/$module_name/state/" 2>/dev/null || true
        fi

        # Copy claude-instructions
        cp "$module_dir/claude-instructions.md" "$INSTALL_DIR/modules/$module_name/" 2>/dev/null || true
    done
fi

# Copy bin/loop
cp "$SCRIPT_DIR/bin/loop" "$INSTALL_DIR/bin-loop"
chmod +x "$INSTALL_DIR/bin-loop"

# Symlink to PATH
ln -sf "$INSTALL_DIR/bin-loop" "$BIN_DIR/loop"

echo ""
echo "Installed."
echo ""

# Check PATH
if ! echo "$PATH" | grep -q "$BIN_DIR"; then
    echo "  Note: $BIN_DIR is not in your PATH."
    echo "  Add this to your shell profile:"
    echo ""
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
fi

# Check Agent Teams
if command -v claude >/dev/null 2>&1; then
    teams_enabled=$(claude config get enableAgentTeams 2>/dev/null || echo "")
    if [ "$teams_enabled" != "true" ]; then
        echo "  Recommendation: enable Agent Teams for best results"
        echo "    claude config set enableAgentTeams true"
        echo ""
    fi
fi

echo "  Run 'loop help' to get started."
echo "  Run 'loop init' in a project directory to set up."
echo ""
