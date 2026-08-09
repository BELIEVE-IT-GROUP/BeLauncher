#!/usr/bin/env bash
set -euo pipefail

# Opt-in spike. It never downloads a model implicitly: pass MODEL_PATH explicitly.
REPO_URL="${LITERT_LM_REPO_URL:-https://github.com/google-ai-edge/LiteRT-LM.git}"
REPO_REF="${LITERT_LM_REPO_REF:-main}"
MODEL_PATH="${MODEL_PATH:-}"
WORK_ROOT="${LITERT_LM_WORK_ROOT:-${TMPDIR:-/tmp}/belauncher-litert-lm-x1}"
SOURCE_DIR="${LITERT_LM_SOURCE_DIR:-$WORK_ROOT/source}"
PROMPT="${PROMPT:-Reply with exactly: X1_OK}"

fail() {
    printf 'X1 blocked: %s\n' "$1" >&2
    exit 2
}

command -v git >/dev/null || fail "git is required"
command -v bazelisk >/dev/null || fail "bazelisk is required (LiteRT-LM pins it through .bazelversion)"
[[ "$(uname -s)" == "Darwin" ]] || fail "this spike targets macOS"
[[ "$(uname -m)" == "arm64" ]] || fail "the recorded target is Apple Silicon arm64"
[[ -n "$MODEL_PATH" && -f "$MODEL_PATH" ]] || fail "MODEL_PATH must point to an existing .litertlm file"

mkdir -p "$WORK_ROOT"
if [[ ! -f "$SOURCE_DIR/.x1-clone-complete" ]]; then
    if [[ -d "$SOURCE_DIR" ]]; then
        mv "$SOURCE_DIR" "$WORK_ROOT/source-incomplete-$(date +%s)"
    fi
    # CPU does not need the repository's large prebuilt accelerator blobs. Keeping LFS smudge
    # disabled makes a failed or repeated spike cheap and leaves GPU packaging as a separate gate.
    GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SOURCE_DIR"
    : > "$SOURCE_DIR/.x1-clone-complete"
fi

cd "$SOURCE_DIR"
EXPECTED_BAZEL="$(tr -d '[:space:]' < .bazelversion)"
[[ "$EXPECTED_BAZEL" == "7.6.1" ]] || fail "unexpected LiteRT-LM Bazel pin: $EXPECTED_BAZEL"

started="$(date +%s)"
bazelisk build //runtime/engine:litert_lm_main --verbose_failures
build_seconds=$(( $(date +%s) - started ))
binary="$SOURCE_DIR/bazel-bin/runtime/engine/litert_lm_main"
[[ -x "$binary" ]] || fail "Bazel reported success but the CLI is missing"
[[ "$(file -b "$binary")" == *"arm64"* ]] || fail "CLI is not an arm64 Mach-O binary"

# The CLI intentionally returns 1 for --help, so validate its diagnostic output rather than
# treating that conventional usage exit as a runtime failure. The CPU run below is the real gate;
# GPU requires separately packaged accelerator dylibs.
help_output="$($binary --help 2>&1 || true)"
grep -q "Flags from" <<< "$help_output" || fail "CLI did not start"
printf 'build_seconds=%s\n' "$build_seconds"
printf 'binary=%s\n' "$binary"
/usr/bin/time -l "$binary" --backend=cpu --model_path="$MODEL_PATH" \
    --input_prompt="$PROMPT"
