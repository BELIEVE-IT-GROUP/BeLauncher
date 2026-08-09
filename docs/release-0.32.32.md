# BeLauncher 0.32.32

## Scope

This release closes the next two AI plan points:

- **A4:** Brain context scopes with a real bounded token budget;
- **A5:** the final privacy boundary before a model request leaves the Mac.

## A4: bounded Brain context

`Retriever.BeBrainContextProvider` now exposes both the requested level and its memory scope:

- `B0` and `B1`: no retrieved Brain evidence;
- `B2`: working context only;
- `B3`: long-term Brain context.

Selection still preserves ranking, source metadata, graph route and the retrieval gap. Passage
selection accounts for the citation envelope as well as text. If a citation cannot fit, it is
omitted and marked truncated instead of returning an over-budget passage. UTF-8 byte accounting
and a final fit loop prevent multibyte text from bypassing the bound. A selected Markdown document
shares the remaining budget with retrieved evidence; when no budget remains it is not appended.

The budget is an explicit conservative estimate, not a claim that every vendor tokenizer has the
same tokenisation. Callers can lower it for smaller local models.

## A5: privacy boundary

`IntelligenceRequest` now carries the Brain context level through `BELModelRequest` to the final
HTTP builder. B2 and B3 require local execution automatically. `localOnly` remains an independent
defence-in-depth flag. The AppDelegate routes Brain questions as local-only before trying a
provider, so a cloud provider is not contacted and then rejected later.

Credential redaction still happens immediately before serialization for cloud providers. Local
providers retain the original text because it does not leave the Mac. A metadata-only
`BELPrivacyAuditEvent` records provider class, sensitivity, Brain scope, local-only decision and
whether system or prompt text was redacted. It contains no prompt, source, credential or payload.

## Verification

- B0/B2/B3 scope tests and zero-budget fail-closed tests.
- UTF-8/multibyte budget test.
- Cloud B3 rejection before request construction.
- Cloud credential redaction and metadata-only audit test.
- Full suite: **1074 tests in 145 suites passed**.

## Remaining plan

N4 Shortcut creation/distribution remains partial because macOS exposes no supported public CLI to
create or import arbitrary shortcuts. N6, N7, A6, A7, A8 and the deferred X1-X5 spikes remain
pending.
