#!/bin/bash
# Builds, signs, notarizes and staples BeLauncher, then produces a DMG ready to publish.
#
# Runs identically on a laptop and on the self-hosted runner, so the pipeline can be
# rehearsed locally before a tag is ever pushed.
#
#   VERSION=0.1.0 bash Scripts/release-mac.sh                  # full run (needs Apple creds)
#   VERSION=0.1.0 SKIP_NOTARIZE=1 bash Scripts/release-mac.sh  # build + sign only
#
# Signing:     MAC_SIGN_IDENTITY (defaults to the Believe Developer ID in the Mac's keychain)
# Notarizing:  APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
IDENTITY="${MAC_SIGN_IDENTITY:-Developer ID Application: BELIEVE IT GROUP SAS (35R4W3WK5T)}"
APP="$ROOT/build/BeLauncher.app"
DIST="$ROOT/dist"
DMG="$DIST/BeLauncher-$VERSION.dmg"

echo "▸ BeLauncher $VERSION"
rm -rf "$ROOT/build" "$DIST"
mkdir -p "$DIST"

# ---------------------------------------------------------------- build (universal)
echo "▸ Building universal binary (arm64 + x86_64)"
bash "$ROOT/Scripts/with-anon-key.sh" swift build -c release --arch arm64 --arch x86_64
BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/BeLauncher"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/BeLauncher"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"

bash "$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns"
# The raw artwork travels too: the app draws it itself in the activation window and the
# command bar, because the system-provided icon comes pre-framed on macOS 26.
[ -f "$ROOT/Resources/AppIcon-1024.png" ] && cp "$ROOT/Resources/AppIcon-1024.png" "$APP/Contents/Resources/AppIconArt.png"

# Everything else in Resources/ goes in as-is. Copying files one by one is what let the mascot
# ship in local builds and not in the release: bundle.sh and this script each had their own list,
# and only one of them was updated. A loop cannot drift; two lists always do.
for asset in "$ROOT/Resources/"*; do
    [ -f "$asset" ] || continue
    case "$(basename "$asset")" in
        AppIcon-1024.png) continue ;;   # already copied above, under its bundle name
    esac
    cp "$asset" "$APP/Contents/Resources/$(basename "$asset")"
done

# And prove it landed, rather than trusting the loop. Same discipline as the entitlement check:
# a release that quietly ships without its artwork looks exactly like one that worked.
for asset in "$ROOT/Resources/"*; do
    [ -f "$asset" ] || continue
    name="$(basename "$asset")"
    [ "$name" = "AppIcon-1024.png" ] && continue
    if [ ! -f "$APP/Contents/Resources/$name" ]; then
        echo "✗ Falta $name dentro del .app" >&2
        exit 1
    fi
done

lipo -archs "$APP/Contents/MacOS/BeLauncher"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/BeLauncher")"
case " $ARCHS " in
    *" arm64 "*) ;;
    *) echo "✗ El binario no contiene arm64." >&2; exit 1 ;;
esac
case " $ARCHS " in
    *" x86_64 "*) ;;
    *) echo "✗ El binario no contiene x86_64." >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- sign
# The Developer ID is imported from Believe's .p12 into a throwaway keychain, which is
# what keeps macOS from opening a password dialog a CI job could never answer.
#
# Note what this deliberately does NOT do: `security list-keychains -s`. Replacing the
# runner's search list would strip the other signing keychains this Mac uses — codesign
# is pointed at the keychain explicitly instead.
P12="${BELIEVE_P12:-$HOME/.believe/apple-devid/developerID.p12}"
P12_PW_FILE="${BELIEVE_P12_PW_FILE:-$HOME/.believe/apple-devid/p12.pw}"

if [ -f "$P12" ] && [ -f "$P12_PW_FILE" ]; then
    # Capture the runner's real search list so it can be put back byte for byte.
    ORIGINAL_KEYCHAINS=()
    while IFS= read -r line; do
        line="${line//\"/}"
        line="$(echo "$line" | xargs)"
        [ -n "$line" ] && ORIGINAL_KEYCHAINS+=("$line")
    done < <(security list-keychains -d user)

    SIGN_KEYCHAIN="${TMPDIR:-/tmp}/belauncher-signing-$$.keychain-db"
    SIGN_KEYCHAIN_PW="$(openssl rand -hex 24)"

    restore_keychains() {
        security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
        security delete-keychain "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
    }
    trap restore_keychains EXIT

    echo "▸ Importing the Developer ID into a throwaway keychain"
    security create-keychain -p "$SIGN_KEYCHAIN_PW" "$SIGN_KEYCHAIN"
    security unlock-keychain -p "$SIGN_KEYCHAIN_PW" "$SIGN_KEYCHAIN"
    security set-keychain-settings -lut 7200 "$SIGN_KEYCHAIN"
    security import "$P12" -k "$SIGN_KEYCHAIN" \
        -P "$(tr -d '\r\n' < "$P12_PW_FILE")" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    # Pre-authorises the private key so codesign never opens a password dialog.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$SIGN_KEYCHAIN_PW" "$SIGN_KEYCHAIN" >/dev/null

    # codesign resolves the private key through the search list, not through --keychain.
    # This Mac holds the SAME Developer ID in another, locked keychain; if that one stays
    # in the list codesign picks it first and dies with errSecInternalComponent. So for the
    # duration of the signing the throwaway keychain is the only one in the list — and the
    # trap above puts the real list back on every exit path, including a crash mid-build.
    security list-keychains -d user -s "$SIGN_KEYCHAIN" >/dev/null
fi

# Hardened runtime and a secure timestamp are both mandatory for notarization.
echo "▸ Signing with: $IDENTITY"
codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/Scripts/BeLauncher.entitlements" \
    --sign "$IDENTITY" \
    --identifier com.believe.belauncher \
    "$APP"
codesign --verify --strict --verbose=2 "$APP"

# A usage string only explains a permission prompt. The hardened binary must also retain the
# matching capabilities or macOS can reject access before TCC registers the app. Inspect the
# signed artifact and fail closed: the source plist is not proof of what codesign emitted.
SIGNED_ENTITLEMENTS_JSON="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null \
    | plutil -convert json -o - -)"
require_entitlement() {
    local key="$1"
    local feature="$2"
    local value
    # plutil treats dots as path separators; entitlement names contain dots literally. JSON with
    # jq's bracket lookup reads the exact key and still distinguishes true from false/missing.
    value="$(printf '%s' "$SIGNED_ENTITLEMENTS_JSON" \
        | jq -r --arg entitlement_key "$key" '.[$entitlement_key] // false')"
    if [ "$value" != "true" ]; then
        echo "✗ El .app se firmó sin $key." >&2
        echo "  $feature no funcionaría y macOS no podría registrar el permiso." >&2
        exit 1
    fi
    echo "▸ Entitlement presente: $key"
}
require_entitlement "com.apple.security.automation.apple-events" "Los comandos de sistema y los flujos"
require_entitlement "com.apple.security.device.audio-input" "El micrófono, el dictado y las notas de voz"

# N7 deliberately does not enable App Sandbox. BeLauncher reads the user's local Mail,
# Messages, Notes and Safari stores after Full Disk Access is granted. Full Disk Access is a
# TCC decision; it does not waive App Sandbox's container/file rules. Adding the sandbox here
# would make those direct reads fail unless the architecture first moved to security-scoped
# bookmarks or a privileged helper. Keep this as a signed-artifact gate so a future entitlement
# edit cannot silently ship a binary that the current source architecture cannot use.
require_absent_entitlement() {
    local key="$1"
    local reason="$2"
    local value
    value="$(printf '%s' "$SIGNED_ENTITLEMENTS_JSON" \
        | jq -r --arg entitlement_key "$key" \
            'if has($entitlement_key) then .[$entitlement_key] else "missing" end')"
    if [ "$value" = "true" ]; then
        echo "✗ El .app declara $key." >&2
        echo "  $reason" >&2
        exit 1
    fi
    echo "▸ Entitlement incompatible ausente: $key"
}
require_absent_entitlement "com.apple.security.app-sandbox" \
    "El acceso directo a Mail, Messages, Notes y Safari requiere el modelo no sandbox actual; migrarlo exige security-scoped bookmarks o un helper y otra auditoría."

require_usage_description() {
    local key="$1"
    local feature="$2"
    local value
    value="$(plutil -extract "$key" raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [ -z "$value" ]; then
        echo "✗ El .app no explica el permiso requerido para $feature ($key)." >&2
        echo "  macOS puede rechazar la solicitud antes de presentar TCC." >&2
        exit 1
    fi
    echo "▸ $key presente"
}
require_usage_description "NSMicrophoneUsageDescription" "micrófono"
require_usage_description "NSCalendarsUsageDescription" "calendario"
require_usage_description "NSAudioCaptureUsageDescription" "audio del sistema"
require_usage_description "NSAppleEventsUsageDescription" "automatización de Apple Events"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "▸ SKIP_NOTARIZE=1 — stopping after signing"
    exit 0
fi

: "${APPLE_ID:?APPLE_ID is required to notarize}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required to notarize}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required to notarize}"

notarize() {
    xcrun notarytool submit "$1" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
}

# ---------------------------------------------------------------- notarize the app
# The .app is notarized and stapled *before* the DMG is built, so the copy the user drags
# into /Applications carries its own ticket and validates with no network.
echo "▸ Notarizing BeLauncher.app"
ditto -c -k --keepParent "$APP" "$DIST/BeLauncher-notarize.zip"
notarize "$DIST/BeLauncher-notarize.zip"
xcrun stapler staple "$APP"
rm -f "$DIST/BeLauncher-notarize.zip"

# ---------------------------------------------------------------- dmg
echo "▸ Building DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "BeLauncher" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "▸ Notarizing the DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------- verify
echo "▸ Verification"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "▸ Done: $DMG"
