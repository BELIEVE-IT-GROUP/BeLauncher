# X2: LiteRT-LM embeddable bridge and model capability spike

Status: **bridge and E4B capability verified; MTP scheduling remains a separate, unenabled spike**.

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

The bridge also calls LiteRT-LM's official `HasSpeculativeDecodingSupport` capability reader before
generation. The Qwen artifact returned `{"speculative_decoding":false}`. The runner supports
`INSPECT_ONLY=1` for metadata-only checks and `REQUIRE_MTP=1` for a fail-closed positive gate; this
avoids allocating the full runtime merely to ask whether an artifact contains a drafter section.

The official `gemma-4-E4B-it.litertlm` artifact then passed both gates: capability inspection returned
`{"speculative_decoding":true}`, and a real CPU generation with the bridge exited 0 and returned
`{"content":"X2_OK","speculative_decoding":true}`. It is 3,659,530,240 bytes with SHA-256
`0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0`. The runtime reported the
model's `decode`, `prefill_128`, `prefill_1024` and `verify` signatures. `/usr/bin/time -l` recorded
7.19 s wall time, 4,885,430,272 bytes maximum resident set and 2,231,621,488 bytes peak footprint
on this 24 GiB arm64 host.

This proves the packaged E4B artifact and upstream capability path, not that the public Conversation
API has an MTP scheduler or that BeLauncher should enable it. The bridge deliberately uses ordinary
conversation generation; the scheduler/acceptance-rate work remains X4.

## Acceptance gates

- Build success is insufficient; the bridge must load the artifact and generate text.
- The response must contain the expected sentinel, not merely a zero exit code.
- The binary must be arm64 on the recorded host.
- A model without verified target/drafter metadata cannot report MTP enabled.
- No fork, model download, or production dependency is introduced by this spike.

## Decision

The C++ bridge path is technically viable and should be revisited only behind an isolated provider
adapter. Do not add it to BeLauncher yet: the GPU accelerator packaging is unresolved from X1, the
user's M1/8 GB memory budget still needs a dedicated benchmark, and the public API does not expose
the MTP scheduler required for a production integration. X2 is complete for the embeddable bridge
and E4B capability sub-gates; X4 remains the separate scheduler decision.
