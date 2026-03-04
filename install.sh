#!/bin/bash
# Simple Loop installer
#
# Copies lib/ and templates/ to ~/.local/share/simple-loop/
# Symlinks bin/loop to ~/.local/bin/loop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${SIMPLE_LOOP_HOME:-$HOME/.local/share/simple-loop}"
BIN_DIR="$HOME/.local/bin"

echo ""
echo "Installing Simple Loop..."
echo "  Source:  $SCRIPT_DIR"
echo "  Install: $INSTALL_DIR"
echo "  Binary:  $BIN_DIR/loop"
echo ""

# Create directories
mkdir -p "$INSTALL_DIR"/{lib,templates/prompts,templates/agents}
mkdir -p "$BIN_DIR"

# Copy lib
cp "$SCRIPT_DIR/lib/daemon.sh" "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/lib/actions.py" "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/lib/assess.py" "$INSTALL_DIR/lib/"
cp "$SCRIPT_DIR/lib/metrics-report.py" "$INSTALL_DIR/lib/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/lib/daemon.sh"

# Copy templates
cp "$SCRIPT_DIR/templates/config.sh" "$INSTALL_DIR/templates/"
cp "$SCRIPT_DIR/templates/brief-template.md" "$INSTALL_DIR/templates/"
cp "$SCRIPT_DIR/templates/prompts/"*.md "$INSTALL_DIR/templates/prompts/"
cp "$SCRIPT_DIR/templates/agents/"*.md "$INSTALL_DIR/templates/agents/"

# Copy bin/loop
cp "$SCRIPT_DIR/bin/loop" "$INSTALL_DIR/bin-loop"
chmod +x "$INSTALL_DIR/bin-loop"

# Symlink to PATH
ln -sf "$INSTALL_DIR/bin-loop" "$BIN_DIR/loop"

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

echo "  Run 'loop help' to get started."
echo "  Run 'loop init' in a project directory to set up."
echo ""
