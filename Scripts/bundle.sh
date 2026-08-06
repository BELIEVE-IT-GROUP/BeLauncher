#!/bin/bash
# Builds BeLauncher.app from the SwiftPM executable.
# Ad-hoc signing is required: TCC (Accessibility) and SMAppService both refuse unsigned bundles.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/BeLauncher.app"

cd "$ROOT"
bash "$ROOT/Scripts/with-anon-key.sh" swift build -c "$CONFIGURATION"
BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/BeLauncher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/BeLauncher"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
bash "$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns"
# The raw artwork travels too: the app draws it itself in the activation window and the
# command bar, because the system-provided icon comes pre-framed on macOS 26.
[ -f "$ROOT/Resources/AppIcon-1024.png" ] && cp "$ROOT/Resources/AppIcon-1024.png" "$APP/Contents/Resources/AppIconArt.png"
# The mascot: shown where the app is seen rarely and large — welcome, empty states, waiting.
[ -f "$ROOT/Resources/Mascot.png" ] && cp "$ROOT/Resources/Mascot.png" "$APP/Contents/Resources/Mascot.png"

codesign --force --deep --sign - --identifier com.believe.belauncher "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc signing failed; Accessibility and launch-at-login may not stick"

echo "Built $APP"
