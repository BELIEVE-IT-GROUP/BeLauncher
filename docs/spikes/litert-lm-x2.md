# X2: LiteRT-LM embeddable bridge and model capability spike

Status: **bridge verified; E4B/MTP remains unverified and is not enabled**.

## Scope

X2 asks whether BeLauncher could embed the upstream C++ runtime without forking its engine, and
whether the target/drafter path is a real capability that can be advertised. The bridge is kept
outside the BeLauncher production target. It is a spike: it must load a model, generate text, and
fail closed when any stage is unavailable.

## Reproduction

```sh
MODEL_PATH=/path/to/model.litertlm \
  Scripts/spike-litert-lm-x2.sh
```

The script uses the upstream checkout at the pinned `.bazelversion`, writes a temporary Bazel target,
builds [`litert_lm_x2_bridge.cc`](../../Scripts/litert-lm-x2-bridge.cc), and requires a response
containing `X2_OK`. It does not download models or alter BeLauncher's Package.swift.

## What upstream actually exposes

The public C++ API has `ModelAssets`, `EngineSettings`, `Engine` and `Conversation`, and the bridge
uses those APIs directly. The source also defines `MTP_DRAFTER` and `MTP_AUX` model section types in
the builder, but that is metadata/model packaging support, not a public target/drafter selection
contract in the `EngineSettings` or `Conversation` API used by this spike.

The tested Qwen3 dynamic INT4 artifact is a single ordinary text model. It generated successfully
through the bridge, but this test does **not** prove MTP or E4B support. A future E4B test must use a
known E4B artifact, inspect its section metadata for both target and drafter sections, and compare
ordinary decode against MTP with the same prompt and output constraints.

## Recorded run

Run date: 2026-08-08 on macOS arm64. Upstream commit: `e533a5ac0da0bd9246d28a57e404f5164c8fa646`.
The model was an explicit local input, not downloaded by the runner:

```text
Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm
size: 344437808 bytes
sha256: e3e290109da4388d65a17510a0c66af91c8039f52d2c465868dbc43c09a776cf
```

The first build completed in 510.453 s from a cold upstream checkout and failed at the initial
factory call because the spike used a non-existent `Engine::CreateEngine` symbol. After correcting
the bridge to the public `EngineFactory::CreateDefault` API, the cached rebuild completed in
7.968 s, produced an arm64 Mach-O, and the real CPU inference exited 0 with:

```json
{"content":"\\n\\nX2_OK"}
```

The bridge deliberately emits only the final `content` channel. It does not expose the model's
internal `thought` or `reasoning_content` fields to a caller. The output sentinel is checked both
inside the bridge and by the shell runner.

## Acceptance gates

- Build success is insufficient; the bridge must load the artifact and generate text.
- The response must contain the expected sentinel, not merely a zero exit code.
- The binary must be arm64 on the recorded host.
- A model without verified target/drafter metadata cannot report MTP enabled.
- No fork, model download, or production dependency is introduced by this spike.

## Decision

The C++ bridge path is technically viable and should be revisited only behind an isolated provider
adapter. Do not add it to BeLauncher yet: E4B/MTP has not passed a model-level validation, the GPU
accelerator packaging is unresolved from X1, and the user's M1/8 GB memory budget still needs a
dedicated benchmark with the exact candidate artifact. X2 is therefore complete for the embeddable
bridge sub-gate, but the E4B/MTP decision remains explicitly open rather than being reported as done.
