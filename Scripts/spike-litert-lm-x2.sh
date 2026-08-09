#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${LITERT_LM_REPO_URL:-https://github.com/google-ai-edge/LiteRT-LM.git}"
REPO_REF="${LITERT_LM_REPO_REF:-main}"
WORK_ROOT="${LITERT_LM_WORK_ROOT:-${TMPDIR:-/tmp}/belauncher-litert-lm-x2}"
SOURCE_DIR="${LITERT_LM_SOURCE_DIR:-$WORK_ROOT/source}"
MODEL_PATH="${MODEL_PATH:-}"
BRIDGE_SOURCE="$(cd "$(dirname "$0")" && pwd)/litert-lm-x2-bridge.cc"

fail() {
    printf 'X2 blocked: %s\n' "$1" >&2
    exit 2
}

command -v git >/dev/null || fail "git is required"
command -v bazelisk >/dev/null || fail "bazelisk is required"
command -v file >/dev/null || fail "file is required"
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] \
    || fail "this spike targets macOS arm64"
[[ -n "$MODEL_PATH" && -f "$MODEL_PATH" ]] \
    || fail "MODEL_PATH must point to an existing .litertlm file"
[[ -f "$BRIDGE_SOURCE" ]] || fail "bridge source is missing"

mkdir -p "$WORK_ROOT"
if [[ ! -d "$SOURCE_DIR/.git" ]] || ! git -C "$SOURCE_DIR" rev-parse HEAD >/dev/null 2>&1; then
    if [[ -d "$SOURCE_DIR" ]]; then
        mv "$SOURCE_DIR" "$WORK_ROOT/source-incomplete-$(date +%s)"
    fi
    GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SOURCE_DIR"
    : > "$SOURCE_DIR/.x2-clone-complete"
fi

cd "$SOURCE_DIR"
expected_bazel="$(tr -d '[:space:]' < .bazelversion)"
[[ "$expected_bazel" == "7.6.1" ]] || fail "unexpected Bazel pin: $expected_bazel"

spike_dir="$SOURCE_DIR/spikes/belauncher_x2"
mkdir -p "$spike_dir"
cp "$BRIDGE_SOURCE" "$spike_dir/litert_lm_x2_bridge.cc"
cat > "$spike_dir/BUILD.bazel" <<'BUILD'
cc_binary(
    name = "litert_lm_x2_bridge",
    srcs = ["litert_lm_x2_bridge.cc"],
    deps = [
        "//runtime/conversation:conversation",
        "//runtime/engine:engine_factory",
        "//runtime/engine:litert_lm_lib",
    ],
)
BUILD

bazelisk build //spikes/belauncher_x2:litert_lm_x2_bridge --verbose_failures
binary="$SOURCE_DIR/bazel-bin/spikes/belauncher_x2/litert_lm_x2_bridge"
[[ -x "$binary" ]] || fail "Bazel reported success but bridge is missing"
[[ "$(file -b "$binary")" == *"arm64"* ]] || fail "bridge is not an arm64 Mach-O binary"

output="$($binary "$MODEL_PATH")" || fail "bridge did not complete inference"
grep -q 'X2_OK' <<< "$output" || fail "bridge response did not contain the expected text"
printf '%s\n' "$output"
