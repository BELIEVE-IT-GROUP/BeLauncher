# BeLauncher 0.32.20

## Purpose

This release packages the work completed after the AI routing and native action audits. It is
intended for installation and manual verification on the Apple Silicon MacBook, especially the
permission and provider flows that cannot be proven by a unit test running in the repository.

The release is documented by evidence. A green Swift test proves a contract or a deterministic
adapter. It does not prove that macOS has granted TCC permission, that Ollama/Qwen is installed on
a particular Mac, or that Apple's notarization service accepted the artifact. Those states are
called out separately below.

## Changes in this release

### 1. Stable BEL action runtime

All migrated actions now pass through the same path:

1. `BELActionCatalog` resolves the stable identifier.
2. `BELActionRuntime` selects the concrete adapter.
3. `BELActionExecutor` checks availability, permissions and confirmation.
4. The adapter performs the system operation and returns a bounded receipt.

The stable identifier is not localized text. This prevents a Spanish/English label change from
breaking the action contract or causing a UI path to bypass the permission gate.

Relevant files:

- `Sources/BeLauncherCore/BELActionDefinition.swift`
- `Sources/BeLauncherCore/BELActionExecution.swift`
- `Sources/BeLauncherCore/BELActionCatalog.swift`
- `Sources/BeLauncher/BELActionRuntime.swift`

### 2. Native actions connected to real APIs

| Stable ID | Adapter | What it does | Permission/confirmation |
| --- | --- | --- | --- |
| `files.open` | `NSWorkspace` | Opens a local file | Files capability |
| `files.reveal` | `NSWorkspace` | Reveals a file in Finder | Files capability |
| `files.move_to_trash` | `FileManager` | Moves a file to Trash | Files capability and explicit confirmation |
| `shortcuts.run` | `/usr/bin/shortcuts` | Runs a named user Shortcut without shell interpolation | Shortcuts capability and confirmation |
| `screen.read_context` | Existing `ScreenCapture` | Reads selected text/document/clipboard context without forcing OCR | No new screen capture escalation |
| `screen.ocr` | Vision plus existing `ScreenCapture` | Captures one requested frame and recognizes text locally | Screen Recording capability |
| `files.extract_pdf_text` | PDFKit | Extracts text from a local PDF without copying it into the Brain | Files capability |
| `calendar.upcoming` | EventKit | Reads the next non-all-day events | Calendar capability |

The screen actions are intentionally separate. Reading the current selection and doing OCR are not
the same privacy event. OCR requires an explicit action and Screen Recording permission.

### 3. App Intents and Shortcuts

`Sources/BeLauncher/AppIntents.swift` exposes three commands to macOS Shortcuts/Siri:

- Open BeBrain.
- Show Clipboard.
- Open BeLauncher Settings.

The intent posts a typed internal notification. `AppDelegate` observes it and routes it to the
existing window methods on the main actor. The intent does not create a second UI or duplicate
launcher behavior.

### 4. Release permission hardening

`Scripts/Info.plist` now declares:

- `NSMicrophoneUsageDescription`
- `NSCalendarsUsageDescription`
- `NSAudioCaptureUsageDescription`
- `NSAppleEventsUsageDescription`

`Scripts/release-mac.sh` fails closed if any of those descriptions is missing. It also checks the
signed artifact for the Apple Events and audio-input entitlements. The source plist alone is not
treated as proof of the signed result.

### 5. Small correctness fixes

File and Shortcut receipts now contain the actual filename/shortcut name. They no longer return the
literal text `url.lastPathComponent` or `shortcut:(name)`, which made a successful action look
untrustworthy in the UI and logs.

## Verification evidence

The repository currently passes:

```text
1043 tests in 144 suites passed
```

The focused permission suite covers entitlements, usage descriptions, release-script checks,
stable native adapter registration, central permission blocking, App Intent delivery and action
confirmation behavior.

The local bundle was built with:

```text
bash Scripts/bundle.sh release
codesign --verify --deep --strict --verbose=2 build/BeLauncher.app
```

Result: the bundle was valid on disk and satisfied its designated requirement. The generated
artifact contained version `0.32.19` during pre-release verification; the signed release build
was checked again by the runner at version `0.32.20`.

## What is not proven by repository tests

These are manual MacBook checks, not claims of completion:

- BeLauncher appears in System Settings > Privacy & Security > Microphone after the signed app
  requests microphone access.
- Calendar permission appears and `calendar.upcoming` returns real events.
- Screen Recording permission appears and OCR returns text from one intentional capture.
- Ollama connectivity and the configured model are healthy on the target Mac.
- Qwen3-ASR can resume/download successfully with the target Mac's disk space and network.
- The launcher remains within the intended startup latency on the user's real corpus.
- The notarized DMG passes `spctl` and stapler validation after the runner finishes.

Those checks require the signed/notarized artifact and the user's machine state. They must be
reported as pass/fail after installation, not inferred from this document.

## Installation and smoke test

After the GitHub release workflow publishes the DMG:

1. Install the new DMG over the existing application. Do not delete the BeLauncher support folder;
   it contains the existing corpus and settings.
2. Open Settings and verify the current version is `0.32.20`.
3. Open the microphone control, approve the permission, stop a short voice note, and verify that
   the recording reaches the transcription review state.
4. Open Settings > Sources and request Calendar. Approve it, then use `prepare me for my next
   meeting` from the launcher.
5. Use the explicit screen/OCR command only after approving Screen Recording.
6. Test one local model and one configured cloud model. Record the provider name and the actual
   error, if any; a generic “connected” state is not evidence.
7. Open Brain, Clipboard and Settings through their App Intent shortcuts.
8. Quit and reopen the app with the corpus intact. Record the startup measurement from diagnostics
   rather than judging it by impression.

## Release procedure

The release is created from `main` with:

```bash
bash Scripts/release.sh patch
git push --follow-tags
```

The tag starts `.github/workflows/release-mac.yml`, which runs the full tests, builds a universal
arm64/x86_64 app, signs it with the Developer ID, notarizes/staples the app and DMG, validates both
artifacts, and publishes the DMG plus update feed.

The audit directories and `docs/plan-action-map-v2.md` are preserved as untracked working evidence;
the release script ignores only those explicit audit artifacts. Any other tracked or untracked
working-tree change still blocks the release.

## Commits included

- `94c7dae` Route local AI through the stable Brain core.
- `5a77679` Centralize stable action execution.
- `efcb8bf` Route file actions through stable BEL handlers.
- `66ede37` Localize stable file actions.
- `b9e9ccd` Execute user Shortcuts through stable actions.
- `534b07b` Expose Brain, Clipboard and Settings through App Intents.
- `f29b746` Expose ScreenCapture, PDFKit and EventKit adapters.
- `6bb247a` Harden native permission release checks.

## Published result

The workflow completed successfully on 2026-08-09:

- Workflow run: `31285863400`
- Duration: 3m 09s
- Test gate: passed, 1043 tests in 144 suites
- Build/sign/notarize gate: passed
- GitHub Release and R2 publication: passed
- Release page: https://github.com/BELIEVE-IT-GROUP/BeLauncher/releases/tag/v0.32.20
- DMG: https://github.com/BELIEVE-IT-GROUP/BeLauncher/releases/download/v0.32.20/BeLauncher-0.32.20.dmg
- SHA-256: https://github.com/BELIEVE-IT-GROUP/BeLauncher/releases/download/v0.32.20/BeLauncher-0.32.20.dmg.sha256

The release is ready for installation. The manual MacBook checks above remain deliberately open:
the CI result proves the artifact and its tests, not the target Mac's TCC state, local models,
network, disk space or corpus startup time. Record those results after installing the DMG.
