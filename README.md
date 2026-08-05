# BeLauncher

A personal, local-only replacement for the parts of Alfred Powerpack I actually use:
a keyboard-first launcher with **search**, **snippets**, **clipboard history** and **workflows**,
living in the menu bar behind a global hotkey.

Swift 6 · SwiftUI + AppKit · SQLite · macOS Keychain · macOS 14+

---

## First run

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
| ⌥Space | Show / hide the command window |
| type | Fuzzy search apps, snippets, clipboard history and workflows |
| ↑ ↓ | Move the selection (wraps) |
| ⇥ | Complete a workflow keyword so you can type its argument |
| ↩ | Run the selection |
| ⌘, | Settings |
| esc | Close |

- **Apps** — `saf` → Safari. Ranking rewards prefixes, word starts and tight matches.
- **Snippets** — a keyword expands to text with tokens: `{clipboard}` `{date}` `{date:EEEE d MMMM}`
  `{time}` `{uuid}` `{cursor}` `{secret:NAME}` `{query}`. Running a snippet copies the result;
  optionally it also pastes into the app you were in (see Permissions).
- **Clipboard history** — an empty query lists recent copies; ↩ copies one back.
- **Workflows** — `gh swift 6` opens `https://github.com/search?q=swift%206`. A workflow is a URL
  template and nothing else.

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
auto-generated items, and anything that is not text. Clipboard history can be turned off entirely.

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

## Deliberately not here

No plugin platform or extension marketplace. No cloud account or cross-device sync. No arbitrary
script execution — workflows open `http`, `https` and `mailto` URLs and nothing else. No billing,
no telemetry, no analytics, no hosted control plane.
