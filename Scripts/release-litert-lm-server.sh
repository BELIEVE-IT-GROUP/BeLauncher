#!/bin/bash
# Builds, signs, notarizes and publishes the litert_lm_server_bridge binary that
# LiteRTLMInstaller downloads on request (see Sources/BeLauncherCore/LiteRTLMInstall.swift).
#
# Same signing/notarizing pattern as Scripts/release-mac.sh (throwaway keychain, p12 import,
# non-interactive), same publish target as the DMG (files.believe-global.com via R2), so this
# runs identically on a laptop or on the self-hosted runner.
#
# bash Scripts/release-litert-lm-server.sh            # full run (needs Apple + R2 creds)
# SKIP_NOTARIZE=1 bash Scripts/release-litert-lm-server.sh   # build + sign only
# SKIP_UPLOAD=1 bash Scripts/release-litert-lm-server.sh     # build + sign + notarize, no publish
#
# Signing:    MAC_SIGN_IDENTITY (defaults to the Believe Developer ID in the Mac's keychain)
# Notarizing: APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID
# Publishing: R2_ACCESS_KEY, R2_SECRET_KEY, R2_ENDPOINT, R2_BUCKET (defaults to believe-r2)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IDENTITY="${MAC_SIGN_IDENTITY:-Developer ID Application: BELIEVE IT GROUP SAS (35R4W3WK5T)}"
DIST="$ROOT/dist"
BINARY_NAME="litert_lm_server_bridge"
# The bridge is not self-contained: it links @rpath/libGemmaModelConstraintProvider.dylib and
# carries a plain @loader_path rpath, so the dylib ships alongside it and LiteRTLMInstaller drops
# both into the same directory. It also has to be re-signed: upstream ships it signed by Google,
# and dyld refuses to map a library whose Team ID differs from the hardened-runtime process.
DYLIB_NAME="libGemmaModelConstraintProvider.dylib"

echo "▸ litert-lm-server-bridge"
mkdir -p "$DIST"

# ---------------------------------------------------------------- build
echo "▸ Building (Bazel, arm64 only — see Scripts/build-litert-lm-server.sh)"
BUILT="$(bash "$ROOT/Scripts/build-litert-lm-server.sh")"
# Removed rather than overwritten: a previous run leaves a signed binary here, and copying onto a
# signed Mach-O in place fails with EACCES.
rm -f "$DIST/$BINARY_NAME" "$DIST/$DYLIB_NAME"
cp "$BUILT" "$DIST/$BINARY_NAME"
chmod +x "$DIST/$BINARY_NAME"

SOURCE_DIR="${BUILT%%/bazel-bin/*}"
cp "$SOURCE_DIR/prebuilt/macos_arm64/$DYLIB_NAME" "$DIST/$DYLIB_NAME"

# ---------------------------------------------------------------- sign
# Identical throwaway-keychain import as release-mac.sh: lets codesign run
# non-interactively even though this Mac also holds the same identity in a locked keychain.
P12="${BELIEVE_P12:-$HOME/.believe/apple-devid/developerID.p12}"
P12_PW_FILE="${BELIEVE_P12_PW_FILE:-$HOME/.believe/apple-devid/p12.pw}"

if [ -f "$P12" ] && [ -f "$P12_PW_FILE" ]; then
    ORIGINAL_KEYCHAINS=()
    while IFS= read -r line; do
        line="${line//\"/}"
        line="$(echo "$line" | xargs)"
        [ -n "$line" ] && ORIGINAL_KEYCHAINS+=("$line")
    done < <(security list-keychains -d user)

    SIGN_KEYCHAIN="${TMPDIR:-/tmp}/belauncher-litertlm-signing-$$.keychain-db"
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
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$SIGN_KEYCHAIN_PW" "$SIGN_KEYCHAIN" >/dev/null
    security list-keychains -d user -s "$SIGN_KEYCHAIN" >/dev/null
fi

echo "▸ Signing with: $IDENTITY"
# Dylib first: signing the executable afterwards is what the loader expects, and both must carry
# our Team ID for dyld to map the library into the hardened-runtime process.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DIST/$DYLIB_NAME"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DIST/$BINARY_NAME"
codesign --verify --strict --verbose=2 "$DIST/$DYLIB_NAME"
codesign --verify --strict --verbose=2 "$DIST/$BINARY_NAME"

# ---------------------------------------------------------------- notarize
if [ "${SKIP_NOTARIZE:-}" != "1" ]; then
    : "${APPLE_ID:?APPLE_ID is required to notarize}"
    : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required to notarize}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required to notarize}"

    echo "▸ Notarizing (bare executable — zipped for submission, not stapled: stapling only
      applies to app bundles/disk images, and this binary is launched via Process(), never
      through LaunchServices, so the notarization ticket check alone is what matters)"
    rm -rf "$DIST/notarize" "$DIST/notarize.zip"
    mkdir -p "$DIST/notarize"
    cp "$DIST/$BINARY_NAME" "$DIST/$DYLIB_NAME" "$DIST/notarize/"
    ditto -c -k --keepParent "$DIST/notarize" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
    rm -rf "$DIST/notarize" "$DIST/notarize.zip"
else
    echo "▸ Skipping notarization (SKIP_NOTARIZE=1)"
fi

echo "▸ Verification"
file "$DIST/$BINARY_NAME"
codesign -dv "$DIST/$BINARY_NAME" 2>&1

shasum -a 256 "$DIST/$BINARY_NAME" "$DIST/$DYLIB_NAME"

# ---------------------------------------------------------------- publish
if [ "${SKIP_UPLOAD:-}" != "1" ]; then
    : "${R2_ACCESS_KEY:?R2_ACCESS_KEY is required to publish}"
    : "${R2_SECRET_KEY:?R2_SECRET_KEY is required to publish}"
    : "${R2_ENDPOINT:?R2_ENDPOINT is required to publish}"
    R2_BUCKET="${R2_BUCKET:-believe-r2}"

    echo "▸ Publishing to files.believe-global.com"
    for pair in "$BINARY_NAME:litert_lm_server_bridge-latest" "$DYLIB_NAME:$DYLIB_NAME"; do
        AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$R2_SECRET_KEY" \
            aws s3 cp "$DIST/${pair%%:*}" \
            "s3://$R2_BUCKET/apps/belauncher/litert-lm/${pair##*:}" \
            --endpoint-url "$R2_ENDPOINT" \
            --content-type "application/octet-stream" \
            --cache-control "public, max-age=60, must-revalidate"
        echo "▸ Published: https://files.believe-global.com/apps/belauncher/litert-lm/${pair##*:}"
    done
else
    echo "▸ Skipping publish (SKIP_UPLOAD=1) — built artifact is at $DIST/$BINARY_NAME"
fi
