# X4: Adaptive MTP scheduler and real execution gate

Status: **scheduler implemented and a real upstream MTP run verified; production integration remains disabled**.

## What was verified

The pinned LiteRT-LM checkout (`e533a5ac0da0bd9246d28a57e404f5164c8fa646`) contains an advanced
CLI path that accepts `--enable_speculative_decoding=true`, discovers the `verify` and
`mtp_drafter` signatures, and runs the upstream drafter. The proof run used the explicit local
E4B artifact:

```text
model: gemma-4-E4B-it.litertlm
sha256: 0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0
backend: cpu
prompt: Reply with exactly: X4_OK
```

The run returned `X4_OK`, exited `0`, logged `mtp_drafter`, and reported `num_correct_tokens: 3`
with success rate `1`. `/usr/bin/time -l` recorded 4,395,106,304 bytes maximum resident set and
3,671,612,208 bytes peak footprint on the 24 GiB development host. Those numbers are not an M1/8
GB guarantee.

An earlier invocation exited `0` with an empty response after `--max_num_tokens=32`; another used
an incompatible bound and failed in `DYNAMIC_UPDATE_SLICE`. Both are rejected by the acceptance
rules. A zero exit code alone is never considered an inference success.

## Policy implemented

`BELMTPScheduler` is a pure local policy gate. It stores only numeric telemetry: model revision,
drafted/accepted counts, timings, memory pressure and failure state. It starts in ordinary decode,
waits for a warm-up sample count, and only selects a compiled draft length from the configured
variants after acceptance and measured speedup clear their thresholds. Model revision changes reset
all evidence. Capability absence, memory pressure, low acceptance, failed cycles or unproven speedup
return ordinary decoding.

The scheduler is intentionally not wired into the production provider yet: the current BeLauncher
provider contract does not expose upstream MTP cycle telemetry. Wiring it without that telemetry
would create a false “adaptive” claim.

## Acceptance gates

- CLI flag is accepted and the model exposes target, verify and drafter signatures.
- Output is non-empty and contains a caller-provided sentinel.
- MTP log evidence reports drafted/accepted work, not just drafter construction.
- Failures and memory pressure force ordinary decoding.
- No prompt, document content or raw token is persisted as scheduler telemetry.
