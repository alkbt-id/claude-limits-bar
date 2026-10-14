#!/bin/bash
# Builds the app, installs it to ~/Applications, enables launch at login and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="io.github.alkbt-id.claude-limits"
DEST="$HOME/Applications/Claude Limits.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./scripts/build.sh

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeLimits 2>/dev/null || true

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "build/Claude Limits.app" "$DEST"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/ClaudeLimits</string></array>
    <key>RunAtLoad</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed: $DEST"
echo "Launch at login: $PLIST"
