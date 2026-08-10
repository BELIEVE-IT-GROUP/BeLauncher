# LiteRT-LM local core: production server bridge

Status: **built and verified end-to-end on real M1/8 GB hardware against the real
`gemma-4-E4B-it.litertlm` model — real HTTP round trips return real generated text. Not yet
wired into `ModelProviderRegistry`.**

## What this is

The direct successor to X2 (`docs/spikes/litert-lm-x2.md`) and X4 (`docs/spikes/litert-lm-x4.md`).
Both proved the upstream C++ API works and that speculative decoding runs, but each invocation
reloaded the model and answered one hardcoded prompt, then exited. That is a spike shape, not a
servicing shape: a real request from BeLauncher needs the model already warm.

Two new files close that gap:

- `Scripts/litert-lm-server-bridge.cc` — loads the model once (same `ModelAssets` /
  `EngineSettings` / `EngineFactory` / `Conversation` calls X2 already proved), then blocks on
  `accept()` and answers `POST /v1/chat/completions` requests over loopback, one at a time. The
  response shape (`choices[0].message.content`) matches `IntelligenceClient.extractText`'s first
  branch exactly, so it needs no new parsing code on the Swift side — it is a drop-in local
  provider once registered.
- `Scripts/build-litert-lm-server.sh` — builds that source against the pinned upstream checkout,
  reusing X2's clone/pin/BUILD.bazel approach, and prints the resulting binary's path.
- `Sources/BeLauncherCore/LiteRTLMService.swift` — a Swift actor that launches the built binary,
  waits for its one-line `{"ready":true,...}` signal on stdout, and stops it. This is the piece
  BeLauncher will call once the binary is bundled.

## What is verified, and how

`Tests/BeLauncherCoreTests/LiteRTLMServiceTests.swift` exercises `LiteRTLMService` against a
stand-in shell script instead of the real bridge — the real binary needs a Bazel build of the
upstream LiteRT-LM checkout and a multi-gigabyte model file, neither of which belongs in a unit
test. Verified there: the service refuses to start against a missing binary or missing model path,
waits for the ready line before returning, reports `isRunning` correctly, refuses a second
concurrent start, and fails closed with `didNotBecomeReady` when a process exits before signalling
ready. All five tests pass; `swift test` for the whole package passes except one pre-existing,
unrelated timing flake in `SearchPerformanceTests`.

## Verified on real hardware (2026-08-10, M1/8 GB)

Steps 1–3 below are now done, on this machine, against the model already present at
`/private/tmp/belauncher-litert-models/gemma-4-E4B-it.litertlm` (3.6 GB, downloaded during the
X2/X4 spikes).

1. **Build.** `MODEL_PATH=... Scripts/build-litert-lm-server.sh` initially failed at the link step:
   `ld: unknown file type in .../libGemmaModelConstraintProvider.dylib`. Cause: the script clones
   with `GIT_LFS_SKIP_SMUDGE=1` (deliberately, to skip the ~6 platforms' worth of prebuilt
   binaries this build doesn't need), but that also left `prebuilt/macos_arm64/*.dylib` — the one
   platform this script *does* need — as unresolved Git LFS pointer text files instead of the real
   Mach-O binaries. Fixed by adding `git lfs pull --include="prebuilt/macos_arm64/*"` right after
   the clone, scoped to just that platform. After the fix, `bazelisk build
   //belauncher/litert_lm_server:litert_lm_server_bridge` completes successfully and produces a
   real arm64 Mach-O executable.
2. **Round trip.** Launched the built binary directly against the real model file. It printed the
   `{"ready":true,"port":8998,"speculative_decoding":true}` line within ~1s (the XNNPACK cache
   files from the prior X2/X4 runs were already on disk next to the model, which is presumably why
   this was fast — a cold cache would likely take longer). Two consecutive real
   `POST /v1/chat/completions` requests (Spanish-language prompts) both returned real generated
   text in the exact `choices[0].message.content` shape `IntelligenceClient.extractText` expects.
   A malformed request correctly returned `400 {"error":"expected messages[].content"}`.
3. **Resource numbers.** RSS after loading the model and serving two requests: **~1.4 GB**.
   Response latency: **~7–9 seconds** for a short (~1–2 sentence) generated answer, running on
   CPU only via XNNPACK — the server log shows both NPU and GPU/Metal acceleration failed to
   register (`NPU accelerator could not be loaded`, `GPU accelerator could not be loaded`), so
   this is CPU-only inference, not the best case this hardware could produce. Rough throughput
   from response length: **~8–9 tokens/sec**. These are single-request numbers from an already-warm
   XNNPACK cache; not a load test, not a cold-start number, and not necessarily representative of
   sustained multi-turn conversation cost (each request currently creates a fresh
   `Conversation` — see below).

## Next steps, in order

1. ~~Run the build on target hardware and confirm it compiles.~~ Done — see above; build script
   fixed.
2. ~~Confirm the OpenAI-compatible round trip returns real generated text.~~ Done — see above.
3. ~~Measure load time, memory, and tokens/sec on the actual M1/8 GB budget.~~ Done — see above.
   ~9 tok/s CPU-only and ~1.4 GB RSS are real numbers now, not projections; NPU/GPU acceleration is
   currently not engaging on this hardware, which is worth its own investigation before treating
   9 tok/s as a ceiling.
4. Register a `belocal-litertlm` entry in `ModelProviderRegistry`, bundle the built binary with the
   signed app, and wire `LiteRTLMService` into app startup/shutdown. Not yet done in this session.
5. Reconnect `BELMTPScheduler` (X4) once the provider contract exposes real MTP cycle telemetry
   from this server, not before — wiring it without that telemetry would be an unproven "adaptive"
   claim, per X4's own acceptance gates.
