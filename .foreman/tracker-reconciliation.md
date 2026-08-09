# Tracker reconciliation (read-only reconnaissance)

Baseline: `36e7aea` / `v0.32.52`.

## Accepted in `main`

- BEL action contract, capability/risk gates, native resolution, Shortcuts, and App Intents are present and covered by tests.
- Wave 1 Brain/Launcher foundations are present: inbox, Markdown read/edit, graph inspection, actions, clipboard history, and launcher entry points.
- Reminders: read/search, lists, create, edit fields, complete/uncomplete, delete, and exact open.
- Contacts: read/search/details, copy, create/update, and exact open.
- Photos: metadata/search, OCR, albums, selective Brain retention, and exact open.
- AI provider/output work exists in history, but the original action-map document is not a current completion ledger.

## Not yet accepted for the user's goal

- Current lead-owned clipboard preview/footer fix is uncommitted and needs independent visual validation on the MacBook before release.
- `contacts.share` is still unavailable; it is the single pilot ticket T-01.
- Photos are not projected into Brain automatically; Reminders and Contacts have selective operational projections. The inclusion policy and user-facing controls need a dedicated verification pass.
- Runtime permission/Automation behavior for Reminders, Contacts, and Photos needs MacBook evidence; unit tests are not proof of TCC behavior.
- The tracker/spec documentation is stale in places and must be reconciled only after behavior is accepted, not used as evidence by itself.
- Remaining AI architecture gaps include runtime Foundation Models capability detection, complete provider boundary unification, real token-budget retrieval, provider-health freshness, cloud-boundary audit metadata, and writeback audit/forget integration.
- LiteRT-LM, CPU/GPU benchmarking, prefix/KV cache, MTP, and fused Metal attention remain deferred spikes. They are not prerequisites for the functional local Brain, but they are still open plan items.

## Acceptance rule

Only a fresh product verification plus lead orchestration audit can move an item from pending to accepted. A green static test without the corresponding MacBook/runtime observation remains partial evidence.
