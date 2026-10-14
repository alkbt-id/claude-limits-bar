#!/bin/bash
# Stops the app, removes it and its login item. History in Application Support is kept.
set -euo pipefail
LABEL="io.github.alkbt-id.claude-limits"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeLimits 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Claude Limits.app"
echo "Removed. History: ~/Library/Application Support/ClaudeLimits/"
