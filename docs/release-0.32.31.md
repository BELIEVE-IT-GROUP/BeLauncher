# BeLauncher 0.32.31

## Scope

This release closes the next two plan points with executable behavior and adversarial tests:

- **N5:** deterministic native/action parsing;
- **A3:** capability- and health-aware model routing.

The resolver and router are now explicit policy boundaries. They do not claim that a declared
catalogue entry or a stale connection is usable.

## N5: deterministic action parsing

`BELActionResolver` now follows this order:

1. exact stable ID or alias;
2. explicit alias/ID prefix with the remaining text as an argument;
3. conservative fuzzy matching only when the confidence is high and no required positional value
   is missing.

Every match carries the stable `actionID`, the legacy-compatible `argument`, a named
`arguments` dictionary, and an integer confidence. Multi-argument actions require explicit
`key=value` syntax; the parser never guesses whether a token is a path, flag, or second argument.

Unavailable seeds and definitions without an executable adapter are excluded before matching.
Native actions with required arguments cannot resolve without those arguments. AI verbs are the
one deliberate exception: their text may come from the selected result or clipboard, and the
existing search layer supplies that source after resolution.

Fuzzy action matching is intentionally stricter because a match can execute a side effect. This
also prevents weak input such as `nav` from surfacing an unrelated system command such as Screen
saver ahead of the user's application search.

## A3: routing with real evidence

Provider health now includes the time it was observed. A route with an explicit health record is
rejected when that evidence is stale, offline, or not suitable for the requested capability.
Missing health remains only a configured fallback; it is never promoted to healthy evidence.

The router now supports:

- required model capabilities (`chat`, `embeddings`, `transcription`, and `web`);
- freshness-required actions, which currently refuse because no registered provider advertises a
  web retrieval capability;
- action route policy (`localOnly`, `localFirst`, and `cloudPreferred`) at the call site;
- network availability filtering for cloud providers;
- machine-aware penalties for critical thermal or memory pressure;
- health cache timestamps propagated from the actual probe clock.

`AIVerbRunner` now passes the action definition's route policy and freshness requirement into the
router, so the policy in the catalogue is used rather than being documentation only.

## Verification

- Resolver tests cover unavailable IDs, incomplete required arguments, named arguments, and
  explicit paths.
- Routing tests cover stale health, missing capabilities, freshness-required routes, privacy, and
  low-memory local preference.
- Full suite: **1070 tests in 145 suites passed**.
- Existing typed AI verb and alias/search tests pass after the stricter resolver integration.

## Still pending

N4 Shortcut creation/distribution remains partial because macOS exposes no supported public CLI to
create or import arbitrary shortcuts. N6 and the remaining plan points are not part of this build.
