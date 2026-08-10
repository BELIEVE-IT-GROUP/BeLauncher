# LiteRT-LM local core: production server bridge

Status: **server bridge and Swift lifecycle manager written and unit-tested; not yet built or run
against a real model on real hardware. Not wired into `ModelProviderRegistry` yet.**

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

What is **not** verified here, because this sandbox has neither the model file nor a live Bazel
build environment:

- That `litert-lm-server-bridge.cc` actually compiles against the real LiteRT-LM headers.
- That a real request round-trips through the socket and returns real generated text.
- Any throughput or memory number on M1/8 GB — X2 and X4's numbers were measured on a 24 GiB host
  and are explicitly not a guarantee for the target hardware.

## Next steps, in order

1. Run `MODEL_PATH=/path/to/gemma-4-E4B-it.litertlm Scripts/build-litert-lm-server.sh` on the
   target Mac to get a real binary, and confirm it compiles.
2. Launch it directly (`./litert_lm_server_bridge model.litertlm 8998`) and `curl` it with a real
   prompt to confirm the OpenAI-compatible round trip actually returns generated text, not just
   that the process starts.
3. Measure load time, memory, and tokens/sec on the actual M1/8 GB budget this project has been
   explicit about — X2/X4's numbers do not transfer.
4. Only then: register a `belocal-litertlm` entry in `ModelProviderRegistry`, bundle the built
   binary with the signed app, and wire `LiteRTLMService` into app startup/shutdown. That is a
   small, mechanical change once 1–3 are done — most of the risk was in the server itself.
5. Reconnect `BELMTPScheduler` (X4) once the provider contract exposes real MTP cycle telemetry
   from this server, not before — wiring it without that telemetry would be an unproven "adaptive"
   claim, per X4's own acceptance gates.
