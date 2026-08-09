# X1: LiteRT-LM source and runtime spike

Status: **complete for the recorded Apple Silicon environment; not an integration decision**.

Date: 2026-08-08

## Question

Can the official LiteRT-LM C++ runtime compile and execute a small local model on macOS arm64,
without forking it or making BeLauncher depend on an unstable Swift preview API?

## Reproduction

The opt-in runner is [`Scripts/spike-litert-lm-x1.sh`](../../Scripts/spike-litert-lm-x1.sh). It is
deliberately explicit about `MODEL_PATH`; it never silently downloads a 300+ MB model or adds one to
the BeLauncher corpus.

```sh
MODEL_PATH=/path/to/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm \
  Scripts/spike-litert-lm-x1.sh
```

The runner checks macOS arm64, the repository's pinned Bazel version, the generated arm64 Mach-O,
CLI startup, and then performs a CPU inference. GPU is not treated as a fallback or as successful
merely because the binary was built.

## Evidence

Source:

- Repository: `https://github.com/google-ai-edge/LiteRT-LM`
- Commit: `e533a5ac0da0bd9246d28a57e404f5164c8fa646`
- `.bazelversion`: `7.6.1`
- Host: macOS `26.6`, Apple Silicon `arm64`, 24 GiB unified memory
- Model: `litert-community/Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm`
- Model SHA-256: `e3e290109da4388d65a17510a0c66af91c8039f52d2c465868dbc43c09a776cf`
- Model size: `344,437,808` bytes

Build:

- Target: `//runtime/engine:litert_lm_main`
- Result: success
- Actions: `5,281`
- Elapsed: `632.695 s`
- Output: arm64 Mach-O, `21,319,936` bytes

CPU run:

- Prompt: `Reply with exactly: X1_OK`
- Process exit: `0`
- Time to first token: `0.68 s`
- Prefill: `24.71 tokens/s` for 15 tokens
- Decode: `13.10 tokens/s` for 218 tokens
- Wall time: `17.66 s`
- Maximum resident set: `2,206,253,056` bytes
- Peak memory footprint: `1,457,373,688` bytes
- The CLI returned text and a benchmark record.

GPU negative control:

- Process exit: `134`
- Cause: the source-built binary could not load the Metal/GPU accelerator dylibs and aborted in
  the executor factory.
- Decision: GPU is **not available** through this spike. It cannot be advertised or selected by
  BeLauncher until a packaging/build mode supplies and verifies the required dylibs.

## Decision

1. Keep the existing LocalHTTP/Ollama/LM Studio path as the production local provider.
2. Do not add LiteRT-LM as a provider in this release: source compilation is reproducible but costs
   roughly ten minutes cold, the Swift API is documented as early preview, and the GPU packaging
   contract is not solved.
3. Keep X2-X5 deferred. The next valid step is a separate adapter spike using a prebuilt Swift SDK
   or a packaged CLI/server, with a memory budget tested on the user's M1/8 GB machine.
4. A successful build alone is not a health signal. Any future adapter must require a real prompt
   response, verified backend, model identity and measured memory before reporting connected.

## External references

- Official build guide: <https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/getting-started/build-and-run.md>
- Official CLI overview: <https://developers.google.com/edge/litert-lm/cli>
- Official platform/API status: <https://developers.google.com/edge/litert-lm/overview>
- Model card and artifact metadata: <https://huggingface.co/litert-community/Qwen3-0.6B>
