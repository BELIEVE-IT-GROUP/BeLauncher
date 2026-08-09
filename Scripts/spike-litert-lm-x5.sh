#!/usr/bin/env bash
set -euo pipefail

# Opt-in probe. It never downloads a model and never falls back from GPU to CPU.
MODEL_PATH="${MODEL_PATH:-}"
SOURCE_DIR="${LITERT_LM_SOURCE_DIR:-}"
PROMPT="${PROMPT:-Reply with exactly: X5_OK}"
EXPECTED="${EXPECTED_OUTPUT:-X5_OK}"

blocked() {
    printf 'X5 blocked: %s\n' "$1" >&2
    exit 2
}

[[ "$(uname -s)" == "Darwin" ]] || blocked "this probe targets macOS"
[[ "$(uname -m)" == "arm64" ]] || blocked "the recorded target is Apple Silicon arm64"
[[ -n "$MODEL_PATH" && -f "$MODEL_PATH" ]] || blocked "MODEL_PATH must point to an existing .litertlm file"
[[ -n "$SOURCE_DIR" && -x "$SOURCE_DIR/bazel-bin/runtime/engine/litert_lm_advanced_main" ]] \
    || blocked "LITERT_LM_SOURCE_DIR must contain the built advanced CLI"

binary="$SOURCE_DIR/bazel-bin/runtime/engine/litert_lm_advanced_main"
stdout_file="${TMPDIR:-/tmp}/belauncher-x5-gpu.stdout"
stderr_file="${TMPDIR:-/tmp}/belauncher-x5-gpu.stderr"
set +e
/usr/bin/time -l "$binary" --model_path="$MODEL_PATH" --backend=gpu \
    --input_prompt="$PROMPT" --max_output_tokens=16 --expected_output="$EXPECTED" \
    >"$stdout_file" 2>"$stderr_file"
code=$?
set -e

if [[ "$code" -eq 0 && -s "$stdout_file" && "$(<"$stdout_file")" == *"$EXPECTED"* ]] \
    && rg -q 'backend: GPU' "$stderr_file" \
    && ! rg -q 'GPU accelerator could not be loaded|MetalAccelerator' "$stderr_file"; then
    printf 'X5 verified: backend=gpu output=%s\n' "$EXPECTED"
    rg -n 'maximum resident set size|peak memory footprint' "$stderr_file" || true
    exit 0
fi

printf 'X5 rejected: GPU execution did not produce verified output (exit=%s)\n' "$code" >&2
rg -n 'Attempting to load GPU|GPU accelerator|MetalAccelerator|backend: GPU|Failed to run' "$stderr_file" >&2 || true
exit 2
