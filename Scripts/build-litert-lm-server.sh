#!/usr/bin/env bash
# Builds litert-lm-server-bridge.cc against the pinned upstream LiteRT-LM checkout and prints the
# resulting binary's path on stdout. This is a build step only: it does not load a model or open
# a port. LiteRTLMService (Sources/BeLauncherCore/LiteRTLMService.swift) launches the printed
# binary directly with `Process` and manages its lifecycle from there — this script does not run
# in the request path.
#
# Reuses the same clone/pin/BUILD.bazel approach verified in docs/spikes/litert-lm-x2.md; the
# only material difference is the source file and its cc_binary name.
set -euo pipefail

REPO_URL="${LITERT_LM_REPO_URL:-https://github.com/google-ai-edge/LiteRT-LM.git}"
REPO_REF="${LITERT_LM_REPO_REF:-main}"
WORK_ROOT="${LITERT_LM_WORK_ROOT:-${TMPDIR:-/tmp}/belauncher-litert-lm-server}"
SOURCE_DIR="${LITERT_LM_SOURCE_DIR:-$WORK_ROOT/source}"
BRIDGE_SOURCE="$(cd "$(dirname "$0")" && pwd)/litert-lm-server-bridge.cc"

fail() {
    printf 'build blocked: %s\n' "$1" >&2
    exit 2
}

command -v git >/dev/null || fail "git is required"
command -v bazelisk >/dev/null || fail "bazelisk is required"
command -v file >/dev/null || fail "file is required"
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
    || fail "this build targets macOS arm64"
[[ -f "$BRIDGE_SOURCE" ]] || fail "bridge source is missing"

command -v git-lfs >/dev/null || fail "git-lfs is required"

mkdir -p "$WORK_ROOT"
if [[ ! -d "$SOURCE_DIR/.git" ]] || ! git -C "$SOURCE_DIR" rev-parse HEAD >/dev/null 2>&1; then
    if [[ -d "$SOURCE_DIR" ]]; then
        mv "$SOURCE_DIR" "$WORK_ROOT/source-incomplete-$(date +%s)"
    fi
    # LFS smudge is skipped on clone to avoid pulling every platform's prebuilt binaries
    # (ios/android/linux/macos, several hundred MB); only macos_arm64 is fetched below,
    # since that is the sole platform this script builds for.
    GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SOURCE_DIR"
fi

cd "$SOURCE_DIR"
git lfs pull --include="prebuilt/macos_arm64/*"
expected_bazel="$(tr -d '[:space:]' < .bazelversion)"
[[ "$expected_bazel" == "7.6.1" ]] || fail "unexpected Bazel pin: $expected_bazel"

build_dir="$SOURCE_DIR/belauncher/litert_lm_server"
mkdir -p "$build_dir"
cp "$BRIDGE_SOURCE" "$build_dir/litert_lm_server_bridge.cc"
cat > "$build_dir/BUILD.bazel" <<'BUILD'
cc_binary(
    name = "litert_lm_server_bridge",
    srcs = ["litert_lm_server_bridge.cc"],
    deps = [
        "//runtime/conversation:conversation",
        "//runtime/engine:engine_factory",
        "//runtime/engine:litert_lm_lib",
        "//schema/capabilities:speculative_decoding",
    ],
)
BUILD

bazelisk build //belauncher/litert_lm_server:litert_lm_server_bridge --verbose_failures
binary="$SOURCE_DIR/bazel-bin/belauncher/litert_lm_server/litert_lm_server_bridge"
[[ -x "$binary" ]] || fail "Bazel reported success but the binary is missing"
[[ "$(file -b "$binary")" == *"arm64"* ]] || fail "binary is not an arm64 Mach-O"

printf '%s\n' "$binary"
