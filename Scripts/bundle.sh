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
# Everything else in Resources/ goes in as-is, by loop rather than by list: naming each file
# here is what let the mascot ship locally and not in the release.
for asset in "$ROOT/Resources/"*; do
    [ -f "$asset" ] || continue
    [ "$(basename "$asset")" = "AppIcon-1024.png" ] && continue
    cp "$asset" "$APP/Contents/Resources/$(basename "$asset")"
done

codesign --force --deep --sign - --identifier com.believe.belauncher "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc signing failed; Accessibility and launch-at-login may not stick"

echo "Built $APP"
