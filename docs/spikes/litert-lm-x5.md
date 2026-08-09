# X5: Metal / fused-attention acceleration gate

Status: **blocked by upstream accelerator packaging; no production feature flag enabled**.

The opt-in probe is [`Scripts/spike-litert-lm-x5.sh`](../../Scripts/spike-litert-lm-x5.sh). It requires
an existing model and an already-built `litert_lm_advanced_main`; it never downloads or silently
falls back to CPU.

```sh
MODEL_PATH=/path/to/model.litertlm \
LITERT_LM_SOURCE_DIR=/path/to/LiteRT-LM \
Scripts/spike-litert-lm-x5.sh
```

On 2026-08-08 the official binary accepted `--backend=gpu` but attempted and failed to load
`libLiteRtGpuAccelerator.dylib`, `libLiteRtWebGpuAccelerator.dylib` and
`libLiteRtMetalAccelerator.dylib`. It registered only `CpuAccelerator` and exited before producing
verified output. The probe returns exit `2` and labels that state **blocked**, rather than reporting
GPU success.

Therefore no Metal attention path is claimed, no GPU fallback is selected in BeLauncher, and no
feature flag is exposed to users. X5 can only be reopened when a packaged accelerator is present,
the same prompt produces verified CPU and GPU outputs, and a benchmark on the target M1/8 GB machine
shows a meaningful latency or memory win without numerical divergence.
