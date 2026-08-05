# BeLauncher

[![Release macOS](https://github.com/BELIEVE-IT-GROUP/BeLauncher/actions/workflows/release-mac.yml/badge.svg)](https://github.com/BELIEVE-IT-GROUP/BeLauncher/actions/workflows/release-mac.yml)

A personal, local-only replacement for the parts of Alfred Powerpack I actually use:
a keyboard-first launcher with **search**, **snippets**, **clipboard history** and **workflows**,
living in the menu bar behind a global hotkey.

Swift 6 · SwiftUI + AppKit · SQLite · macOS Keychain · macOS 14+

---

## Install

Download the latest signed and notarized build:

**[Latest release on GitHub](https://github.com/BELIEVE-IT-GROUP/BeLauncher/releases/latest)** ·
[direct download](https://files.believe-global.com/apps/belauncher/BeLauncher-latest.dmg)

The GitHub link is the one to share: the `latest.dmg` name never changes, so a CDN can serve a
stale copy of it. Versioned files (`BeLauncher-0.5.0.dmg`) are always exact, and that is what the
in-app update check downloads.

Open the DMG, drag BeLauncher to Applications, launch it. It is signed with the Believe Developer
ID and notarized by Apple, so there is no "unidentified developer" warning and no right-click-open
dance. Verify it yourself with:

```
spctl --assess --type execute --verbose=2 /Applications/BeLauncher.app
# → accepted, source=Notarized Developer ID
```

## First run (from source)

```
make run
```

That builds `build/BeLauncher.app`, ad-hoc signs it and launches it. BeLauncher appears in the menu bar
(no Dock icon). Press **⌥Space** to open the command window.

Other commands: `make test`, `make build`, `make clean`, `make uninstall`.

No `.env` is needed to run. Copy `.env.example` to `.env` only if you want the optional update
feed. `.env` is git-ignored; credentials never belong in the repo.

## Using it

| Key | Action |
| --- | --- |
| ⇧⌘Space | Show / hide the command window |
| ⌥C | Open straight into clipboard history |
| type | Fuzzy search apps, snippets, clipboard history and workflows |
| ↑ ↓ | Move the selection (wraps) |
| ⇥ | Complete a workflow keyword so you can type its argument |
| ↩ | Run the selection |
| ⌘↩ | Reveal the selected app or file in Finder |
| ⌘, | Settings |
| esc | Close |

- **Apps** — `saf` → Safari. Ranking rewards prefixes, word starts and tight matches.
- **Snippets** — a keyword expands to text with tokens: `{clipboard}` `{date}` `{date:EEEE d MMMM}`
  `{time}` `{uuid}` `{cursor}` `{secret:NAME}` `{query}`. Running a snippet copies the result;
  optionally it also pastes into the app you were in (see Permissions).
- **Clipboard history** — an empty query lists recent copies; ↩ copies one back.
- **Workflows** — `gh swift 6` opens `https://github.com/search?q=swift%206`. A workflow is a URL
  template and nothing else. Add as many as you like.
- **Calculation** — `2+2`, `(4+6)/4`, `2^10`, `200+10%`, `15% of 300`. ↩ copies the raw result.
- **Conversion** — `10 km to mi`, `100 c to f`, `1 gb to mb`, `2 h to min`, `5 km a millas`.
  Length, mass, temperature, time and data, all computed locally.
- **Flows** — a keyword that runs several steps in order: `enfoque` → silence notifications,
  open Notion and Terminal, start a 50 minute timer. You build them in Settings by picking a step
  kind and filling one field; there is no scripting language to learn.
- **Files** — `f budget` searches file names through Spotlight's existing index. ↩ opens,
  ⌘↩ reveals in Finder.

## Architecture

```
Sources/BeLauncherCore/     no AppKit, no UI — this is what the tests drive
  Database.swift        ~120-line SQLite wrapper (system libsqlite3, no dependencies)
  Store.swift           snippets / workflows / clips / settings + migrations, seeding, trimming
  Models.swift          types + input validation
  SnippetExpander.swift the core transformation: template → text (+ cursor offset)
  WorkflowURL.swift     template → URL, scheme allow-list
  FuzzyMatch.swift      ranking + matched indices for highlighting
  SearchEngine.swift    one query → ranked results across all four sources
  LauncherModel.swift   the keyboard state machine (loading/empty/results/noMatch/failed)
  Calculator.swift      arithmetic, percentages and unit conversion, all local
  FileSearch.swift      file names via Spotlight's index, behind the explicit "f " prefix
  SecretGuard.swift     keeps credentials out of the clipboard history
  License.swift         key/email normalisation, outcomes, the 30-day re-check rule
  LicenseClient.swift   the two endpoints plus the Keychain vault
  Flow.swift            the step catalogue plus validation
  FlowRunner.swift      flow → ordered list of actions (pure, so flows are testable)
  ExportImport.swift    JSON archive in and out
  Keychain.swift        {secret:NAME} values
  Env.swift, SafeFilename.swift, Diagnostics.swift, AppIndex.swift

Sources/BeLauncher/         the shell: AppKit windowing + SwiftUI views
  AppDelegate.swift     wiring, status item, actions
  HotKey.swift          Carbon global hotkey (no permission required)
  CommandPanel.swift    borderless floating panel, top-anchored, resizes with content
  CommandView.swift     the command window (glass, states, result rows)
  SettingsView.swift    the single settings screen
  ClipboardWatcher.swift, Permissions.swift, LaunchAtLogin.swift, UpdateCheck.swift
```

`BeLauncherCore` has no UI dependency on purpose: every decision the window makes — what matches,
what is selected, what Enter does — is testable without a screen.

## Licensing

BeLauncher is paid, one licence for life, up to **3 Macs**. On first launch it asks for the
purchase email and the key (`BELN-XXXX-XXXX-XXXX`) and validates them against the server; the app
never issues licences of its own.

- This Mac is identified by its **hardware UUID** (`IOPlatformUUID`) plus a readable machine name.
- On success the activation is stored in the **Keychain** and BeLauncher works offline from then
  on. It is not re-validated at every launch — at most once every 30 days, and a failed check
  never locks a Mac that was already activated.
- If the licence is already on 3 Macs, the screen lists them and offers to free one.
- Settings › Licencia has **Desactivar en este equipo**, which frees this seat.

Endpoints (`…/functions/v1/belauncher_landing_44aa9b_`): `validate-license` and
`deactivate-device`. The Supabase anon key is public by design and is substituted into the build
by `Scripts/with-anon-key.sh`, so the repository itself carries only a placeholder.

## Permissions

BeLauncher asks for **one** permission, and only when you turn on the feature that needs it:

| Permission | When | Why |
| --- | --- | --- |
| Accessibility | Only when you enable "Paste into the frontmost app after choosing an item" | macOS only lets an app press ⌘V in another app with this permission. BeLauncher uses it for nothing else. |

Turning that toggle on shows an explanation first, and only opens System Settings if you agree.
Decline and everything else keeps working; pasting stays a manual ⌘V.

Everything else needs no permission at all: the global hotkey uses Carbon, the app list is a
directory scan, and clipboard history reads the pasteboard, which macOS does not gate.

**What is never captured:** items marked concealed (password managers), transient or
auto-generated items, anything that is not text, and — importantly — **anything that looks like a
credential**. `SecretGuard` refuses Stripe/GitHub/Slack/AWS/OpenAI-shaped tokens, `*_SECRET=`
style assignments, private-key blocks and JWTs, and it purges any that an older build already
captured, on every launch. This is not hypothetical: a live Stripe key turned up in a real
history during development. Clipboard history can also be turned off entirely.

## Where your data lives

```
~/Library/Application Support/BeLauncher/belauncher.sqlite3   snippets, workflows, clipboard, settings
~/Library/Application Support/BeLauncher/.env             optional config (not created for you)
Keychain, service "com.believe.belauncher.secrets"       {secret:NAME} values
```

The database directory is created with `0700`. Nothing is written anywhere else, and nothing
leaves the machine — there is no account, no sync, no telemetry and no server. The only network
call BeLauncher can make is the update check, which requires both an explicit opt-in *and* a feed URL
in `.env`.

## Backup and export

- **Settings › Your data › Export…** writes readable JSON: snippets, workflows and settings.
  Clipboard history is excluded unless you pick "Export with clipboard history…". Secrets are
  never exported.
- **Import…** merges by keyword and never overwrites: entries that already exist are skipped and
  reported.
- For a full backup, copy `~/Library/Application Support/BeLauncher/`. Quit BeLauncher first so SQLite's
  WAL is checkpointed.
- **Export diagnostics…** writes a plain-text report (versions, counts, paths, toggles). It
  deliberately contains no snippet bodies, no clipboard text and no secret values, so you can read
  it before sharing it.

## Uninstall

1. Quit BeLauncher from the menu bar.
2. Turn off "Launch at login" first (or run `make uninstall`, which handles the rest).
3. Delete `BeLauncher.app`.
4. Delete `~/Library/Application Support/BeLauncher`.
5. If you stored secrets: open Keychain Access and delete items with the service
   `com.believe.belauncher.secrets`.

`make uninstall` does steps 1, 3 and 4 and reminds you about 5.

## Releasing

```
bash Scripts/release.sh patch     # bumps the version and tags it
git push --follow-tags            # the tag starts the release
```

The `Release macOS` workflow runs on the **self-hosted Apple Silicon runner** registered at the
BELIEVE-IT-GROUP org level (GitHub-hosted macOS runners bill 10x; this one bills nothing). It:

1. runs the tests,
2. builds a universal binary (arm64 + x86_64),
3. signs with `Developer ID Application: BELIEVE IT GROUP SAS` and the hardened runtime,
4. notarizes and staples **both** the `.app` and the DMG, so the copy in `/Applications` validates
   with no network,
5. attaches the DMG to the GitHub Release,
6. publishes the DMG and `latest.json` to Cloudflare R2 (`believe-r2`), served from
   `files.believe-global.com/apps/belauncher/`.

To rehearse it locally without touching Apple's servers:

```
VERSION=0.1.0 SKIP_NOTARIZE=1 bash Scripts/release-mac.sh
```

Signing has one non-obvious requirement, learned the hard way. `codesign` resolves the private
key through the **keychain search list**, not through `--keychain`, and this Mac holds the same
Developer ID in a second, locked keychain. If that one is in the list, codesign picks it first and
fails with `errSecInternalComponent`. So `release-mac.sh`:

1. imports `~/.believe/apple-devid/developerID.p12` into a throwaway keychain,
2. pre-authorises the key with `set-key-partition-list` (no password dialog a CI job could answer),
3. makes that keychain the **only** one in the search list while it signs,
4. restores the real search list and deletes the throwaway keychain on every exit path.

Step 4 matters: the runner is a real Mac with other signing keychains, and leaving a truncated
search list behind would break unrelated builds.

Repository secrets used by the workflow: `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`,
`APPLE_TEAM_ID`, `MAC_SIGN_IDENTITY`, `R2_ACCESS_KEY`, `R2_SECRET_KEY`, `R2_ENDPOINT`,
`R2_BUCKET`. All of them come from Infisical; none of them live in the repo.

## The icon

`Resources/AppIcon-1024.png` is the artwork of record — drop a 1024×1024 PNG there and the build
turns it into `AppIcon.icns`. Without it, `Scripts/draw-icon.swift` draws the mark in code so a
build never ships a blank tile. The same glyph is drawn as a vector in `BrandMark.swift` for the
search field and the menu bar, where it is rendered as a monochrome template image.


## Tests

```
make test      # or: swift test
```

40 tests, all against `BeLauncherCore`:

- **Transformation** — snippet expansion (every token, cursor offset, escaping, unknown tokens),
  workflow URL building and the scheme allow-list, fuzzy ranking, safe filenames, `.env` parsing.
- **Store** — validation, clipboard dedup and trimming, settings, export/import round-trip,
  future-format rejection, diagnostics redaction.
- **End-to-end keyboard workflow** — summon → type → ↑↓ → ↩ for each result kind, plus escape,
  empty results, and the loading / no-match / recoverable-failure states.

The keyboard tests drive `LauncherModel` through the exact entry point the panel's key monitor
calls. SwiftPM cannot host an XCUITest target for a menu-bar-only executable, so the "UI test" is
an end-to-end test of the full keyboard loop rather than a screen-driven one; the SwiftUI layer
above it holds no logic of its own.

## What a flow can do (and what it deliberately cannot)

A flow is a named chain of steps from a **closed catalogue** that BeLauncher implements itself:

| Step | Does |
| --- | --- |
| Open app / Open file / Open URL | launches it |
| Copy text / Paste snippet | puts text on the clipboard, snippets expanded at run time |
| Run shortcut | runs a shortcut **you already built** in Apple's Shortcuts app |
| Start timer | schedules a local notification |
| Wait | pauses before the next step |

"Run shortcut" is the only step that reaches outside BeLauncher, and it is how a flow silences
notifications or sets a Focus: macOS exposes those only through Shortcuts. The name is passed as a
process argument to `/usr/bin/shortcuts`, never through a shell, so a name cannot become a command.
BeLauncher does not create, edit or import shortcuts.

There is no "run this script" step, on purpose. A launcher that executes arbitrary shell or
AppleScript is one imported flow away from being a malware delivery mechanism, and the whole point
of this app is that nothing runs that you did not explicitly build.

## Deliberately not here

No plugin platform or extension marketplace. No cloud account or cross-device sync. No arbitrary
script execution — workflows open `http`, `https` and `mailto` URLs and nothing else. No billing,
no telemetry, no analytics, no hosted control plane.
