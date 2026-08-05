#!/bin/bash
# Builds BeLauncher.app from the SwiftPM executable.
# Ad-hoc signing is required: TCC (Accessibility) and SMAppService both refuse unsigned bundles.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/BeLauncher.app"

cd "$ROOT"
swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/BeLauncher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/BeLauncher"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - --identifier com.believe.belauncher "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc signing failed; Accessibility and launch-at-login may not stick"

echo "Built $APP"
