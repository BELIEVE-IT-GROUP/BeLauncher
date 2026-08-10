# LiteRT-LM local core: production server bridge

Status: **built, wired into `ModelProviderRegistry` and app startup/shutdown, and verified
end-to-end on real M1/8 GB hardware against the real `gemma-4-E4B-it.litertlm` model — real HTTP
round trips return real generated text, and the local-provider discovery path
(`LocalModels.installed()`) finds it exactly like it finds Ollama or LM Studio. Signed, notarized
and published for download on request — see "Distribution" below.**

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

## Registered and wired (2026-08-10)

1. ~~Run the build on target hardware and confirm it compiles.~~ Done — see above; build script
   fixed.
2. ~~Confirm the OpenAI-compatible round trip returns real generated text.~~ Done — see above.
3. ~~Measure load time, memory, and tokens/sec on the actual M1/8 GB budget.~~ Done — see above.
   ~9 tok/s CPU-only and ~1.4 GB RSS are real numbers now, not projections; NPU/GPU acceleration is
   currently not engaging on this hardware, which is worth its own investigation before treating
   9 tok/s as a ceiling.
4. ~~Register a `litertlm` entry in `ModelProviderRegistry` and wire `LiteRTLMService` into app
   startup/shutdown.~~ Done:
   - `litert-lm-server-bridge.cc` now answers `GET /v1/models` with the LM Studio-shaped
     `{"data":[{"id":"..."}]}` `LocalModels.models(in:)` already parses — without this, the bridge
     could serve chat completions but `LocalModels.installed()` would never see it, because that is
     the ping every local provider is discovered through. Rebuilt and verified against the real
     model: both `/v1/models` and `/v1/chat/completions` respond correctly on real hardware.
   - `ModelProviderRegistry.all` has a `litertlm` entry (`transport: .local`,
     `defaultModel: "gemma-4-E4B-it"`), which `IntelligenceProvider.all` picks up automatically —
     no separate catalogue to maintain.
   - `LiteRTLMLocalCore` (in `LiteRTLMService.swift`) defines the path convention: binary and model
     are expected at `Application Support/BeLauncher/LocalCore/`, overridable via
     `LITERT_LM_BINARY_PATH` / `LITERT_LM_MODEL_PATH` for development against a Bazel output
     directory. `isAvailable` is true only when both files actually exist there.
   - `AppDelegate.finishLaunch(store:)` calls `startLiteRTLMIfAvailable()`, which is a no-op unless
     `LiteRTLMLocalCore.isAvailable`; `applicationWillTerminate` stops the service. On every real
     user's machine today this is a no-op, identical to Ollama not being installed — nothing
     bundles the binary or the model yet (see below).
   - Verified end-to-end on real hardware: with the binary and model at the env-var-overridden
     paths, `LocalModels.installed()` reports `litertlm` as running with model
     `gemma-4-E4B-it` — the same discovery path `askModel` already uses for every other local
     provider, unmodified.
5. Reconnect `BELMTPScheduler` (X4) once the provider contract exposes real MTP cycle telemetry
   from this server, not before — wiring it without that telemetry would be an unproven "adaptive"
   claim, per X4's own acceptance gates.

## Verified on real hardware (2026-08-10, Mac mini M4 / 24 GB)

Second machine, downloaded through the shipped path (E4B, the variant a 24 GB Mac gets):

| | M1 / 8 GB | Mac mini M4 / 24 GB |
|---|---|---|
| Startup to first response | ~30 s | 19 s |
| One-sentence answer | ~9 s | 6.8 s |
| ~100-word answer | — | 11 s |
| Throughput | ~8-9 tok/s | ~13-16 tok/s |

Still CPU-only: the NPU registry fails with `kLiteRtStatusErrorInvalidArgument` and every GPU
accelerator (including `libLiteRtMetalAccelerator.dylib`) fails to load, exactly as on the M1. The
M4 is faster because its CPU is faster, not because anything is being accelerated — which is the
argument for measuring the 12B variant before offering it, rather than assuming a bigger Mac can
carry a bigger model.

**Disk, not memory, is what actually broke it.** On first run XNNPACK builds a weight cache next to
the model (`<model>_<mtime>_<size>.xnnpack_cache`, **2.1 GB** for E4B) and calls `abort()` if it
cannot finish writing — the server died with SIGABRT at 664 MB of cache on a Mac with 825 MB free,
*after* a fully successful 3.7 GB download. `requiredDiskBytes` reserved 300 MB of slack, which was
never going to be enough; it now reserves the model's size a second time.

## Distribution: downloaded on request, never bundled (2026-08-10)

Nothing ships inside the signed `.app`. The engine and the model are fetched only when a person
asks for them — from the onboarding step (`WelcomeView`) or from Settings → Intelligence
(`SettingsView`) — by `LiteRTLMInstaller`, with resumable `URLSessionDownloadTask` transfers and a
cancel that keeps what already came down. Everything else in BeLauncher works whether or not they
ever download it.

Which model a Mac downloads depends on its physical memory, not on a fixed choice: 8 GB or less
gets **E2B** (2.6 GB), more than 8 GB gets **E4B** (3.7 GB). E4B was verified to run on an M1/8 GB
at ~1.4 GB resident, but with nothing to spare next to everything else a person has open; E2B
leaves that room and answers faster. The 12B (6.5 GB) and 31B variants exist upstream and are
deliberately not offered — the bridge is CPU-only through XNNPACK here, and nobody has measured
those sizes on Apple silicon, so offering one would trade a slow answer for a bigger download.
A Mac that already downloaded a different variant keeps using it (`LiteRTLMLocalCore.modelPath()`
prefers what is on disk) instead of paying for the download twice.

What gets published, by `Scripts/release-litert-lm-server.sh` on the same self-hosted runner as the
DMG (`.github/workflows/release-litert-lm-server.yml`), signed with the Believe Developer ID and
notarized by Apple:

- `litert_lm_server_bridge-latest` (~21 MB)
- `libGemmaModelConstraintProvider.dylib` (~9 MB)

Two files, not one: the bridge links the library through `@rpath` and carries a plain
`@loader_path` rpath, so both land in the same directory and no archive needs unpacking. The
library also has to be **re-signed** — upstream ships it signed by Google, and dyld refuses to map
a library whose Team ID differs from the hardened-runtime process loading it (`different Team
IDs`). Both are notarized together in one submission. The bare executable is not stapled: stapling
matters for bundles opened through LaunchServices, and this one is launched via `Process()`.

Verified end-to-end on 2026-08-10: both files downloaded from
`files.believe-global.com/apps/belauncher/litert-lm/`, marked with a quarantine xattr, and the
bridge runs (`usage: litert_lm_server_bridge MODEL_PATH PORT`) with matching SHA-256 and a valid
signature.

## What is still open

5. Reconnecting `BELMTPScheduler` (X4) — deliberately not done: it needs real MTP cycle telemetry
   from this server first, and wiring it without that telemetry would be an unproven "adaptive"
   claim, per X4's own acceptance gates.
