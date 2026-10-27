#!/bin/bash
# Builds build/Claude Limits.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

# Some Swift 6.4 setups fail in the new build system ("Unknown error parsing property list");
# the old one still builds the same binary.
FLAGS=(-c release)
if ! swift build "${FLAGS[@]}"; then
    echo "Retrying with the native build system"
    FLAGS+=(--build-system native)
    swift build "${FLAGS[@]}"
fi
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/ClaudeLimits"
APP="build/Claude Limits.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeLimits"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature with a designated requirement on the bundle id only: macOS privacy permissions
# (Accessibility, Automation) are tied to it and survive rebuilds instead of resetting each time.
codesign --force --sign - -r='designated => identifier "io.github.alkbt-id.claude-limits"' "$APP" >/dev/null
echo "Built: $APP"
