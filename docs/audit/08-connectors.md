# Auditoría 08 — Conectores locales y captura

Alcance: correo/mensajes/notas locales, captura de audio/pantalla/llamadas, portapapeles, historial de navegadores, transcripción.
Método: lectura completa de los 21 archivos asignados + rastreo real de usos (`grep`) + revisión de `Tests/BeLauncherAppTests/`. Solo lectura, no se modificó nada.

## 0. Corrección del estado de git (el brief está desactualizado)

El brief afirmaba que `QwenASR.swift` y `LocalMailConnector.swift` estaban "modificados sin commitear en esta sesión", que HEAD era `de18ca2` con 16 archivos modificados, y que el último commit era "fix: make microphone TCC and Qwen disk checks real". **Nada de eso corresponde al disco ahora:**

- HEAD real: `7eec075 fix: diagnose silent voice recordings`.
- Único archivo trackeado modificado: `Sources/BeLauncher/AppIntents.swift` (+119/−30), fuera de este alcance.
- Ni `QwenASR.swift` ni `LocalMailConnector.swift` tienen cambios sin commitear.

Todo lo que sigue describe el código commiteado en `7eec075`.

---

## 1. Mapa de responsabilidades

### 1.1 Conectores locales de lectura

**`Sources/BeLauncher/LocalMailConnector.swift` (134 líneas)** — lectura acotada y de solo lectura del store `.emlx` de Apple Mail.
- `enum LocalMailConnector` (:9)
- `struct Reading: Sendable { let messages: [MailMessage]; let problem: String? }` (:10-13)
- `static func mailRoot(home: String = NSHomeDirectory()) -> URL?` (:15-28) — elige la carpeta `V<n>` de mayor número bajo `~/Library/Mail`; no asume `V10`.
- `static func read(since: Date, home: String = NSHomeDirectory(), limit: Int = 300) -> Reading` (:30-60) — enumera `.emlx` (ignora `.partial.emlx`), corta en `limit * 2` (:52), ordena desc (:55), devuelve `prefix(limit)`.
- `private static func isExcluded(_ path: String) -> Bool` (:62-67) — excluye `drafts/junk/deleted messages/trash/papelera/outbox/sendlater/send later`.
- `private static func readPrefix(_ path: String) -> String?` (:69-74) — lee solo 128 KB por mensaje.
- `private static func parse(_ raw: String, path: String, since: Date) -> MailMessage?` (:76-104) — desdobla headers plegados (:80-85), fecha desde `Date:` o `modificationDate` (:92-93), descarta sin asunto (:97), marca `isFlagged` por `x-apple-mail-flag` (:102) e `isSent` por ruta (:103).
- Privadas: `parseDate` (:106-115, dos formatos RFC, locale `en_US_POSIX` armado desde bytes), `decodeHeader` (:117-122, strip ingenuo de `=?utf-8?Q?`), `cleanExcerpt` (:124-133, regex HTML + quoted-printable parcial + tope 2000 chars).
- Dependencias: `Foundation`, `BeLauncherCore` (`MailMessage`, `L`).

**`Sources/BeLauncher/LocalMessagesConnector.swift` (91 líneas)** — lectura de `~/Library/Messages/chat.db`.
- `struct Reading { let messages: [MessageRecord]; let problem: String? }`
- `private struct OpenedDatabase { let handle: OpaquePointer; let directory: URL }`
- `static func read(since:home:limit: Int = 300) -> Reading` (:18) — SQL en :32-39: `SELECT m.guid, m.text, m.date, m.is_from_me, COALESCE(h.id,'') FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id WHERE m.date > ? AND m.text IS NOT NULL … AND COALESCE(m.is_system_message,0)=0 ORDER BY m.date DESC LIMIT ?`.
- Doble época Apple (:60-62): `rawDate > 10_000_000_000 ? Double(rawDate)/1e9 + 978_307_200 : Double(rawDate) + 978_307_200`.
- `private static func openCopy(_ url: URL) -> OpenedDatabase?` (:72-90) — copia db + `-wal` + `-shm` a temp y abre `SQLITE_OPEN_READONLY`.
- Dependencias: `SQLite3` C API directo, `BeLauncherCore` (`MessageRecord`).

**`Sources/BeLauncher/LocalNotesConnector.swift` (90 líneas)** — lectura de `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`.
- `struct Reading { let notes: [NoteRecord]; let problem: String? }`
- `static func read(since:home:limit: Int = 300) -> Reading` — SQL en :24-30 sobre `ZICCLOUDSYNCINGOBJECT` con **`Z_ENT = 12` hardcodeado** y `ZMARKEDFORDELETION = 0`.
- Filtro de ruido: `clean.count >= 40` (:48).
- `private struct SQLiteReadOnly { openSnapshot(at:); prepare(_:); close() }` (:58-90) — tercera implementación del mismo patrón snapshot.

**`Sources/BeLauncher/BrowserHistory.swift` (219 líneas)** — Safari + Chrome/perfiles.
- `appleEpochOffset = 978_307_200`, `windowsEpochOffset = 11_644_473_600`.
- `struct Reading { let visits: [BrowserVisit]; let problems: [String] }`
- `static func read(since:excludedDomains:excludedApps:limit: Int = 3_000, home:) -> Reading` (:46-76) — aplica `Privacy.isExcluded` **en el momento de leer**, no después.
- `safari(at:since:limit:)` (:80-96), `chromeProfiles(home:)` (:104-113, cubre `Default` y `Profile *`), `chrome(at:since:limit:)` (:115-130).
- `withCopy(of:_:)` (:140-163) — **cuarta** copia del patrón snapshot SQLite.
- `query(_:_:floor:limit:make:)` (:167-196) — descarta filas con título vacío.
- `enum Failure { case unreadable(String), queryFailed(String) }`; `describe(_:browser:)` (:210-218) produce la frase de Full Disk Access.

**`Sources/BeLauncher/LocalSourceHealth.swift` (59 líneas)** — `@MainActor enum`, traduce ajustes + existencia de archivos a estado de UI.
- `static func state(for source: KnowledgeSource, store: Store) -> KnowledgeSource.State` (:7-27).
- `static func successfulSync(_ id: String, store: Store) -> Bool` (:29-47) — exige `source_enabled_<id>` + `source_last_sync_<id> > 0` + `source_last_problem_<id>` vacío + una sonda de evidencia por id (`mailRoot() != nil`, existe `chat.db`, existe `NoteStore.sqlite`).
- `static func browserAvailable(home:) -> Bool` (:49-58).

### 1.2 Captura de audio / llamadas

**`Sources/BeLauncher/AudioCaptureController.swift` (205 líneas)** — `@MainActor final class : NSObject, AVAudioRecorderDelegate, ObservableObject`.
- `enum State: Equatable { case idle, recording(started: Date), transcribing }` (:11-15)
- `@Published private(set) var state: State = .idle` (:24), `@Published private(set) var message = ""` (:25)
- `var stateLabel: String` (:27-33), `var recordingStartedAt: Date?` (:35-38), `var isRecording: Bool` (:47-50)
- `init(notify: @escaping (String) -> Void, onSaved: @escaping () -> Void = {}, targetApplication: @escaping () -> NSRunningApplication? = { nil })` (:40-45)
- `static func pruneRecordings(olderThan age: TimeInterval = 30*24*60*60)` (:52-62)
- `func toggleVoiceNote()` (:64), `func toggleDictation()` (:68), `func startVoiceNote()` (:72), `func stopVoiceNote()` (:121)
- `private func startRecording(shouldPaste:)` (:77-119) — Accesibilidad solo si va a pegar (:83), `Permissions.requestMicrophone()` (:90), archivo `voice-<epoch>.m4a` en `Vault.recordingsRoot()` (:99-100), AAC/44100/mono/high (:101-106).
- `private func finishedRecording(successfully:)` (:132-189) — `VoiceProvider.transcribe(fileAt:title:"Voice note")` (:150), `vault.saveEvidence(title:text:"Audio: <path>\n\n<texto>", at:sourcePath:)` (:152-156); si `paste`, limpia pasteboard, activa el target y llama `Permissions.pasteToFrontmostApp()` tras 0.15 s (:161-168); en error guarda una nota "Voice note awaiting transcription" (:178-184).
- `private enum Failure: LocalizedError { case couldNotStart }` (:196-204)

**`Sources/BeLauncher/CallCaptureController.swift` (138 líneas)** — `@MainActor final class : NSObject, AVAudioRecorderDelegate`.
- `enum State { case idle, recording(started: Date), transcribing }`
- Posee `private let system = SystemAudioCapture()` y `private let detector = CallAppDetector()`; expone `source: CallAudioSource`, `onSuggestionChange`, `suggestedAppName`, `suggestedSource`, `likelyInCall`.
- `start()` (:47-86) — exige micrófono **y** `SystemAudioCapture.permissionGranted` (si no, `requestPermission()` + aviso); resuelve `.automatic` → `detector.suggestedSource ?? .system`; crea `Vault.recordingsRoot()/call-<epoch>/` con `microphone.m4a` + `system.caf`.
- `finish(successfully:)` (:98-128) — transcribe ambas pistas en paralelo (`async let yours` / `async let theirs`), arma un cuerpo con ambas rutas y secciones "You:" / "Other participants:", guarda **un** documento de evidencia `Call <ISO8601>`, llama `onSaved()` y `onCompleted(title, body)`; en error guarda "Call awaiting transcription".

**`Sources/BeLauncher/SystemAudioCapture.swift` (108 líneas)** — `@MainActor final class : NSObject, SCStreamOutput, SCStreamDelegate`.
- `static var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }` (:20); `static func requestPermission()` (:22).
- `func start(to url: URL, source: CallAudioSource = .system) async throws` — `SCContentFilter` por app cuando la fuente nombra bundles, si no el display completo; `SCStreamConfiguration` con `capturesAudio = true`, `sampleRate = 48_000`, `channelCount = 2`, `queueDepth = 5`, `width/height = 2`.
- `func stop() async`.
- `private var failed: Error?` (:18) — escrito en `didStopWithError` (:74-78) y en el `catch` de `append` (:94-96).
- `private enum Failure { case permission, noDisplay }` (:99-100)

**`Sources/BeLauncher/CallAppDetector.swift` (112 líneas)** — `@MainActor final class : ObservableObject`; `@Published private(set) var suggestedSource / suggestedAppName / likelyInCall`; `start()` (:21-23) instala observer de `didActivateApplicationNotification` + `Timer` cada 2 s; `refresh()` (:34-67) recorre frontmost + apps de conferencia conocidas; `windowLooksLikeCall` (:94-102) matchea `["zoom meeting","zoom webinar","meeting","call","reunion"]`; `windowNames(for:)` (:104-111) vía `CGWindowListCopyWindowInfo`.

**`Sources/BeLauncherCore/CallAudioSource.swift` (34 líneas)** — `public enum CallAudioSource: String, CaseIterable, Identifiable, Sendable { case automatic, zoom, teams, meet, system }` con `title` y `bundleIdentifiers` (zoom `us.zoom.xos`; teams `com.microsoft.teams2`/`com.microsoft.teams`; meet = 8 bundles de navegador).

### 1.3 Transcripción

**`Sources/BeLauncher/QwenASR.swift` (749 líneas)** — dos tipos: `QwenASRInstaller` (`@MainActor @Observable final class`, `static let shared`) y `enum QwenASRRuntime`.
- `enum Phase: Equatable { case unknown, unavailable, pythonMissing, notInstalled, installing, ready(model: String), failed(String) }` (:12-20)
- Constantes (:22-29): `smallModel = "mlx-community/Qwen3-ASR-0.6B-bf16"`, `largeModel = "…-1.7B-bf16"`, `requiredPython = "3.10–3.13"`, `requiredDiskBytes: Int64 = 6_000_000_000`, `uvVersion = "0.12.3"`, `engineVersion = "0.2.0"`, `selectedModelDefaultsKey = "qwen_asr_selected_model"`.
- `var root: URL` = `~/Library/Application Support/BeLauncher/ASR` (:60-63); `var python: URL` = `root/.venv/bin/python3` (:65).
- `private struct InstallRecord: Codable` con `Status { installing, ready, failed, cancelled }`, persistido en `install-state.json` (:52-58, :121).
- `struct InstallationState: Equatable { pythonPresent, enginePresent, modelPresent; var isReady; var canResume }` (:111-118).
- `var isAvailable: Bool` — `#if arch(arm64) true #else false` (:131-137).
- API: `refresh()`, `install()`, `cancel()`, `isInstalling`, `isReady`, `canResume`.
- Verificación **real** (no simulada): `nonisolated static func inspect(root:model:modelCacheRoots:) -> InstallationState` (:292-303) exige `python3` ejecutable **y** `pyvenv.cfg`; `engineInstalled` (:305-315) exige que el marcador `.engine-0.2.0.ready` contenga `engineVersion` **y** exista `qwen3_asr_mlx/__init__.py` real; `modelSnapshotExists` (:330-341) exige snapshot con `config.json`; `snapshotWeightsAreComplete` (:343-360) parsea `weight_map` de `model.safetensors.index.json` y exige todos los shards; `weightFileIsComplete` (:362-369) resuelve symlinks y exige `size > 1_048_576`.
- `freeDiskSpace(at:)` (:240-251) con el fix documentado de bridging de `NSNumber`.
- `ensureUV(at:)` (:508-545) — descarga `uv` desde GitHub con SHA256 pineado.
- `private final class ProcessRun: @unchecked Sendable` (:388-462) — subproceso cancelable, stderr a log temporal 0600.
- `QwenASRRuntime.transcribe(fileAt:model:)` (:592-623) — exige `inspect(...).isReady`, normaliza audio, exige `duration >= 0.25` (si no `.audioTooShort`) y `peak >= 0.0005 && rms >= 0.00005` (si no `.silentAudio`).
- `transcriptText(from:)` (:625-637) descarta `Fetching N files:` y barras `%|`. `audioSignalSummary(for:)` (:639-677).

**`Sources/BeLauncher/Transcription.swift` (293 líneas)** — camino Apple SpeechAnalyzer, solo on-device, macOS 26+.
- `isSupported`, `unsupportedReason`, `preferredLocale(chosen:)` (:61-82), `availableLocales()`, `suggestsDownload(_:)` (pista, nunca gate), `installModel(for:)`.
- `selfTest(locale:) -> Double` (:130-140) — habla una frase conocida y compara; `agreement(spoken:heard:)` (:148-152); `isTrustworthy(_:)`; `trustBar: Double = 0.7` (:162).
- `enum Failure { case tooOld, noLanguage, untrustworthy(Double), empty }`.
- `transcribe(fileAt:title:spokenLanguage:verify: Bool = true)` (:222-243); `run(fileAt:locale:)` (:253-292) con `AssetInventory.reserve/release` liberado manualmente en ambas salidas.

**`Sources/BeLauncher/VoiceProvider.swift` (55 líneas)** — `enum Kind { qwen, appleSpeech }`; `static func providerOrder(qwenReady: Bool) -> [Kind]` → `[.qwen, .appleSpeech]` o `[.appleSpeech]`; `transcribe(fileAt:title:spokenLanguage:) async throws -> Transcript` recorre el orden acumulando `"<provider>: <error>"` y lanza `Failure.allProviders([String])`.

### 1.4 Portapapeles, pantalla, servicios

**`Sources/BeLauncher/ClipboardWatcher.swift` (99 líneas)** — `@MainActor final class`; `Timer` de 0.7 s en `RunLoop.main` modo `.common` (:23-27); `ignoreNextChange()`; `poll()` (:55-98) descarta `org.nspasteboard.ConcealedType/TransientType/AutoGeneratedType`, atiende primero URLs de archivo (`recordClip(kind: .file)` + `OperatingModel.observeFilename`), luego texto (`recordClip` + `OperatingModel.observeWriting`), luego imágenes (guardadas en `<store dir>/clipboard-images/clip-<epoch>.png`).

**`Sources/BeLauncher/ScreenCapture.swift` (145 líneas)** — `@MainActor enum`; `static func read(whole: Bool = false) async -> ScreenContext` (:31-49) intenta en orden: texto seleccionado por AX → OCR de pantalla completa (opcional) → ruta del documento frontmost → portapapeles. `selectedText()` (:57-74), `frontmostDocumentPath()` (:77-94), `recogniseScreen()` (:103-123, `VNRecognizeTextRequest` `.accurate`, idiomas `["es-ES","en-US"]`), `captureScreen()` (:125-130, usa el deprecado `CGWindowListCreateImage`), `screenRecordingGranted` / `requestScreenRecording()`.

**`Sources/BeLauncherCore/ScreenContext.swift` (264 líneas)** — `public struct ScreenContext { text, origin: Origin(.selection/.recognised/.file/.clipboard), application, path }`; `public enum ScreenReader` con `Subject` (error/invoice/email/table/code/design/link/prose), `Offer { id, title, symbol, verb }`, `subject(of:)`, `offers(for:)` (exactamente 3 por subject), `minimumLength = 12`, `isWorthOffering(_:)`, `instruction(for verb:)`.

**`Sources/BeLauncher/ServiceProvider.swift` (80 líneas)** — `@MainActor final class : NSObject`; closures `runVerb`, `writeNote`, `remember`; `static func install(_:)` fija `NSApp.servicesProvider` + `NSUpdateDynamicServices()`; entradas `@objc`: `translate`, `summarise`, `fix`, `extractTasks`, `note`, `rememberThis`.

### 1.5 UI del subsistema

**`Sources/BeLauncher/SourceCenterView.swift` (193 líneas)** — `struct SourcesTab: View` con `@Bindable var model: SettingsModel` y `@State private var health = CapabilityHealth()`. Banner de Full Disk Access (:12-30); toggle del grafo + `model.corpusStatusLine` + `corpusLastProblem` + `sourceFeedback["all"]` + botón "Sync all" (:32-67); `ForEach(KnowledgeSourceCatalog.current) { SourceRow(...) }` (:69-73); refresco en `onAppear` + `didBecomeActiveNotification` + `didActivateApplicationNotification` (:76-88). `private struct SourceRow` (:92-193): símbolo, título, `stateLabel` (Connected/Available/Manual/Planned), `stateColor` (verde/naranja/secondary), `source.scope`, `model.sourceStatusLine(source.id)`; `@ViewBuilder private var action` conmuta por id.

**`Sources/BeLauncher/CaptureStatusPanel.swift` (111 líneas)** — `@MainActor final class CaptureStatusPanel: NSPanel`, borderless + nonactivating, `level = .floating`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient]` (:22-23); `init(controller:openBrain:newNote:)` (:12-30); `present()` (:32-40) lo posiciona a 24 pt de la esquina superior derecha de la pantalla bajo el mouse. `private struct CaptureStatusView` (:44-107): icono (`record.circle.fill`/`waveform`/`checkmark.circle.fill`), `controller.stateLabel`, `controller.message` (por defecto "Your audio stays on this Mac", :58), `TimelineView(.periodic(by: 1))` con MM:SS (:64-70), botones Stop / Open Brain / New note (:72-84).

**`Sources/BeLauncher/CallReviewView.swift` (183 líneas)** — `@MainActor final class CallReviewModel: ObservableObject` con `title`, `transcript`, `analyze: (String) async throws -> String` y `save: (String,String) throws -> Void` inyectados, `@Published analysis/working/error/saved`; `extractActions()` manda un prompt fijo pidiendo `## Decisions / ## Commitments / ## Tasks / ## Open questions`; `saveAnalysis()`. `struct CallReviewView: View` — HSplitView transcripción / propuestas, toolbar "Extract actions" + "Save proposals", pie "Audio stays on this Mac." / "Proposals are not committed automatically."

### 1.6 Puente al grafo

**`Sources/BeLauncherCore/Capture.swift` (219 líneas)** — `public enum Capture`; `public struct Event { let node: WorkNode; let links: [WorkEdge] }`. Relevantes a este subsistema: `mail(_ message: MailMessage) -> Event` (:154-163, kind `.conversation`, target = ruta `.emlx`), `message(_ record: MessageRecord) -> Event` (:165-171), `note(_ record: NoteRecord) -> Event` (:173-179). Además `events(from:)`, `person(named:at:)`, `company(fromEmail:)`, `file(at:at:)`, `project(forPath:)`, `application(named:path:at:)`, `memory(_:fromMeeting:)`, `sessionWindow = 1_800`, `sessions(_:window:)`.

---

## 2. Grafo de relaciones — pipeline real

### 2.1 Conectores → Corpus → Brain (verificado)

Los tres `Local*Connector` y `BrowserHistory` **solo** se invocan desde dos lugares:

1. `Sources/BeLauncher/CorpusRunner.swift` — gates por fuente en :186-193 (`source_enabled_browsers|conversations|apple-mail|messages|notes`), lectura fuera del main actor en :197-215: `BrowserHistory.read` (:200), `Self.conversations` (:203), `LocalMailConnector.read` (:204), `LocalMessagesConnector.read` (:207), `LocalNotesConnector.read` (:210).
2. `Sources/BeLauncher/main.swift` — camino CLI/diagnóstico: `BrowserHistory.read` (:60), `LocalMailConnector.read` (:65), `LocalMessagesConnector.read` (:69), `LocalNotesConnector.read` (:73).

De ahí:

```
Local*Connector.read(since:)                      CorpusRunner.swift:200-211
  → assemblyInput()                               CorpusRunner.swift:404-429
      mails.filter(MailRelevance.isWorthIndexing).map(Capture.mail).map(\.node)     :411
      messages.filter { $0.text.count >= 40 }.map(Capture.message).map(\.node)      :413
      notes.filter { count >= 40 && !SecretGuard.carriesSecret }.map(Capture.note)  :415
      + store.nodes(limit: 2_000).filter { lastSeen >= since && !id.hasPrefix("episode:") }  :417-418
  → CorpusBuilder.assemble(input)   (fuera del actor)                CorpusRunner.swift:231-233
  → re-chequeo isCapturing && !corpus.isPaused                       CorpusRunner.swift:236
  → write(corpus) → store.replacePassagesChecked(for:title:occurredAt:text:)  :440-462
  → recordSource(id, enabled:count:problem:)  → source_last_sync_<id> / _count_ / _problem_   ~:329-345
```

Dos detalles importantes y verificados:
- `store.nodes(...)` excluye explícitamente los nodos `episode:` (:418) — **no hay bucle de retroalimentación** de episodios derivados hacia el corpus.
- `recordSource` se llama **después** de escribir, no después de leer. El comentario en :260-261 lo dice: una lectura exitosa no es una sincronización exitosa hasta que la compuerta de privacidad permitió commitear el corpus ensamblado.

### 2.2 Audio y llamadas → NO pasan por el corpus

`AudioCaptureController` y `CallCaptureController` **no** alimentan `CorpusRunner`. Escriben documentos de evidencia directo al Vault:
- Nota de voz: `vault.saveEvidence(title:text:"Audio: <path>\n\n<texto>", at:sourcePath:)` (`AudioCaptureController.swift:152-156`).
- Llamada: un documento `Call <ISO8601>` con ambas rutas de audio y secciones "You:" / "Other participants:" (`CallCaptureController.swift:98-128`).

El único puente audio→corpus es indirecto y opt-in: `CorpusRunner.transcribePending(since:)` (:610-658), que solo corre cuando `source == nil` (:216) y solo si el usuario configuró `transcription_folder`. Extensiones aceptadas: `["m4a","mp3","wav","aiff","caf","mp4","mov"]`; registro `transcribed_files` topado en 500; backoff exponencial `min(24h, 30min * 2^(n-1))` en `transcription_retry_count`/`transcription_retry_after`; **exactamente un archivo por pasada** (`break` al final del bucle).

Consecuencia: las grabaciones que produce la propia app en `Vault.recordingsRoot()` **no** se transcriben por esta vía salvo que el usuario apunte `transcription_folder` ahí. No verificado que la UI ofrezca hacerlo.

### 2.3 Cadena de transcripción

```
AudioCaptureController.finishedRecording  →  VoiceProvider.transcribe(fileAt:title:)   :150
CallCaptureController.finish              →  VoiceProvider.transcribe (×2 en paralelo)
CorpusRunner.transcribePending            →  VoiceProvider.transcribe
        VoiceProvider.providerOrder(qwenReady:)  → [.qwen, .appleSpeech] | [.appleSpeech]
            .qwen        → QwenASRRuntime.transcribe(fileAt:model:)   QwenASR.swift:592
            .appleSpeech → Transcription.transcribe(fileAt:…verify:)  Transcription.swift:222
```

### 2.4 Cableado en `AppDelegate.swift`

- `audioCapture = AudioCaptureController(...)` (:341-350), con `targetApplication` resolviendo la app frontmost no-propia o `appBeforePanel`.
- `capturePanel = CaptureStatusPanel(controller:openBrain:newNote:)` (:353-356).
- `callCapture = CallCaptureController(...)` (:358-364), con `source: CallAudioSource(rawValue: store.setting("call_audio_source") ?? "") ?? .automatic`.
- `AudioCaptureController.pruneRecordings()` (:367).
- `ClipboardWatcher(store:)` arrancado si `clipboard_enabled` (:381-383).
- `openCallReview(title:transcript:)` (:848-870) arma `CallReviewModel` con `askModel(prompt, sensitivity: .confidential)` y una closure de guardado que escribe `"<title> - actions"` al Vault.
- `retryTranscription(_:)` (:1260-1283).
- `Capture.*` usado en :685, :1374, :1448, :1454, :1459, :1467, :1847, :1859. `ScreenCapture.read()` en :1388 y :1508.

### 2.5 Estado → UI

`SettingsModel.swift:1176-1355` es el único traductor de settings a texto de UI: `corpusStatusLine` (:1185-1206), `sourceEnabled`/`setSourceEnabled` (:1214-1221), `syncSource(_:)` (:1223-1236, restringido a `["apple-mail","messages","notes","browsers","conversations"]`), `syncAllSources()` (:1238-1250), `sourceMessage(_:)` (:1257-1265), `sourceIsSyncing(_:)` (:1267-1269), `sourceStatusLine(_:)` (:1284-1300), `sourceHasSuccessfulSync(_:)` (:1304-1306). `SourceCenterView` consume todo esto; `LocalSourceHealth.state(for:store:)` decide el color/etiqueta.

---

## 3. Variables y estado

### 3.1 En disco

| Qué | Dónde | Formato |
|---|---|---|
| Modelo/venv Qwen | `~/Library/Application Support/BeLauncher/ASR` (`QwenASR.swift:60-63`) | venv Python + caché HF snapshots |
| Estado de instalación Qwen | `<ASR>/install-state.json` (:121) | JSON `InstallRecord` (:52-58) |
| Marcador de engine | `<ASR>/.venv/…/.engine-0.2.0.ready` (:305-315) | texto = `engineVersion` |
| Log stderr del subproceso | temp, permisos 0600 (`ProcessRun`, :388-462) | texto |
| Notas de voz | `Vault.recordingsRoot()/voice-<epoch>.m4a` (`AudioCaptureController.swift:99-100`) | AAC m4a 44.1 kHz mono |
| Llamadas | `Vault.recordingsRoot()/call-<epoch>/{microphone.m4a, system.caf}` (`CallCaptureController.swift:47-86`) | AAC + CAF |
| Imágenes del portapapeles | `<store dir>/clipboard-images/clip-<epoch>.png` (`ClipboardWatcher.swift`) | PNG |
| WAV normalizado temporal | `FileManager.temporaryDirectory/belauncher-asr-….wav` (`QwenASR.swift:685-686`) | WAV (ver §4, bug) |
| Copias snapshot SQLite | directorio temporal, db + `-wal` + `-shm` | SQLite, borrado tras leer |
| Documentos de evidencia | Vault (`Vault.saveEvidence`) | markdown |
| Pasajes del corpus | `store.replacePassagesChecked` (`CorpusRunner.swift:440-462`) | tabla del Store |

### 3.2 Settings (`store.setting` / `setSetting`) que gobiernan este subsistema

`source_enabled_<id>`, `source_last_sync_<id>`, `source_last_count_<id>`, `source_last_problem_<id>` (por id: `apple-mail`, `messages`, `notes`, `browsers`, `conversations`); `clipboard_enabled`; `call_audio_source`; `corpus_last_passages`, `corpus_last_deferral`; `transcription_folder`, `transcribed_files` (tope 500), `transcription_retry_count`, `transcription_retry_after`, `transcription_last_problem`. En `UserDefaults`: `qwen_asr_selected_model` (`QwenASR.swift:29`).

### 3.3 En memoria

- `AudioCaptureController`: `state` (`.idle/.recording(started:)/.transcribing`), `message`, `recorder`, `recordingURL`, `shouldPaste`, `pasteTarget`.
- `CallCaptureController`: mismo `State` + `system`, `detector`, `source`.
- `CallAppDetector`: `suggestedSource`, `suggestedAppName`, `likelyInCall`, refrescados por `Timer` de 2 s.
- `SystemAudioCapture`: `stream`, `file`, `destination`, `failed` (ver §4).
- `ClipboardWatcher`: contador de cambios del `NSPasteboard` + flag `ignoreNextChange`.
- `SettingsModel`: `sourceRefreshRevision: Int`, `sourceSyncing: Set<String>`, `sourceFeedback: [String:String]`, `sourceFeedbackErrors: [String:Bool]` (:1252-1255).
- `QwenASRInstaller.shared`: `Phase` observable.

### 3.4 El estado "está sincronizando ahora"

Vive **solo en memoria** (`SettingsModel.sourceSyncing`, :1254). `sourceIsSyncing(_:)` (:1267-1269) devuelve true si el id o `"all"` está en el set. Si la app se reinicia mientras un corpus corre, ese estado desaparece; lo que persiste es `source_last_sync_<id>` y el checkpoint del corpus, no un "in flight".

---

## 4. Funciones incompletas / stubs / TODOs / chequeos simulados

**No hay ni un solo `TODO`, `FIXME`, `fatalError` ni `not implemented` en `Sources/`** (verificado por grep sobre todo el directorio). Lo que hay son tres defectos concretos y tres puntos ciegos.

### 4.1 Defecto: interpolación rota, nombre de temp constante — `QwenASR.swift:685-686`

```swift
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("belauncher-asr-(UUID().uuidString).wav")
```

Falta la barra invertida. El nombre resultante es la cadena literal `belauncher-asr-(UUID().uuidString).wav`, **constante**. Dos normalizaciones concurrentes (por ejemplo las dos pistas de una llamada, que `CallCaptureController.finish` lanza con `async let` en paralelo) escriben y borran el mismo archivo. Riesgo real de transcripción cruzada o corrupta en llamadas.

### 4.2 Defecto: imagen del portapapeles guardada dos veces — `ClipboardWatcher.swift:92-95`

```swift
store.recordClip(text: saveImage(image, source: source) ?? "Imagen copiada",
                 sourceApp: source, kind: .image,
                 assetPath: saveImage(image, source: source) ?? "")
```

`saveImage` se llama dos veces por cada imagen copiada: se escriben dos PNG (nombres `clip-<epoch>.png`, colisionan o no según el segundo), y el `text` del clip queda con la ruta del **primer** archivo mientras `assetPath` apunta al **segundo**. Consumo de disco duplicado y posible desalineación ruta/asset.

### 4.3 Punto ciego: error de captura de audio del sistema nunca se muestra — `SystemAudioCapture.swift:18, :74-78, :94-96`

`private var failed: Error?` se escribe en `didStopWithError` (:74-78) y en el `catch` de `append` (:94-96), y **nunca se lee en ninguna parte del proyecto** (verificado por grep). Si el `SCStream` muere a mitad de una llamada, la grabación de la otra parte se corta en silencio: `CallCaptureController` sigue en `.recording`, el usuario no ve nada y al finalizar obtiene un `system.caf` truncado que se transcribe como si estuviera completo. Es exactamente la clase de "chequeo que no chequea" que motivó el trabajo reciente sobre TCC/Qwen, y quedó fuera de ese barrido.

### 4.4 Punto ciego: "Connected" no significa que se haya leído

`LocalSourceHealth.successfulSync` (:29-47) exige `source_enabled_<id>` + `source_last_sync_<id> > 0` + `source_last_problem_<id>` vacío + **existencia** del archivo (`mailRoot() != nil`, existe `chat.db`, existe `NoteStore.sqlite`). Es más honesto que un booleano de settings, pero no prueba legibilidad actual: si se revoca Full Disk Access después de una sincronización exitosa, la fila sigue en verde "Connected" hasta la próxima corrida. `Permissions.fullDiskAccessLikely` sí abre y lee 1 byte, pero alimenta el banner superior, no el estado por fuente.

### 4.5 Punto ciego: la fila "audio" es una etiqueta estática

En `SourceCenterView.swift` el `@ViewBuilder private var action` (:~130-190) para el id `audio` devuelve un `Text(L("Manual"))` fijo. No refleja permiso de micrófono, ni si Qwen está listo, ni si hay una carpeta de transcripción configurada, ni el `transcription_last_problem` que `CorpusRunner` sí escribe. Es un estado simulado en el sentido literal: un texto constante donde debería haber un estado.

### 4.6 Asimetría de honestidad entre proveedores de transcripción

`Transcription` tiene `selfTest(locale:)` (:130-140), `agreement(spoken:heard:)` (:148-152) y `trustBar = 0.7` (:162), y `transcribe(...verify: Bool = true)` lanza `.untrustworthy(score)` cuando no llega. El camino Qwen (`QwenASR.swift:592-623`) valida el **audio de entrada** (duración, pico, RMS) pero no verifica la **salida**: no hay equivalente a `selfTest`. Como `providerOrder` pone `.qwen` primero cuando está listo (`VoiceProvider.swift`), el camino habitual del usuario en Apple Silicon es el que menos garantías tiene.

---

## 5. Deuda técnica

### 5.1 Los tres `Local*Connector` no comparten nada. La rueda está reinventada 4 veces.

Respondiendo la pregunta directa del brief: **no hay base común**. Solo se repite, informalmente, la forma `Reading { items, problem: String? }`.

El patrón "copiar la DB + sidecars `-wal`/`-shm` a temp y abrir `SQLITE_OPEN_READONLY`" está implementado **cuatro veces, en cuatro formas distintas**:

| Implementación | Archivo | Forma |
|---|---|---|
| `openCopy(_:) -> OpenedDatabase?` | `LocalMessagesConnector.swift:72-90` | función + struct local `OpenedDatabase` |
| `struct SQLiteReadOnly` | `LocalNotesConnector.swift:58-90` | struct privado con `openSnapshot/prepare/close` |
| `withCopy(of:_:)` | `BrowserHistory.swift:140-163` | closure scoped, usado para Safari **y** Chrome |
| (Mail no usa SQLite) | `LocalMailConnector.swift` | recorrido de filesystem + parser propio |

Cuatro manejos distintos de errores, de limpieza del temp y de mensajes de problema. Un bug de fuga de archivos temporales o de manejo de `-wal` hay que arreglarlo en tres lugares. `BrowserHistory.withCopy` es la versión más madura (scoped, limpia por `defer`) y sería el candidato natural a extraer a `BeLauncherCore`.

### 5.2 `Z_ENT = 12` hardcodeado — `LocalNotesConnector.swift:24-30`

El id de entidad de Core Data de Apple Notes está pineado a 12. Ese número no es estable entre versiones de macOS ni entre migraciones del store. Si cambia, la consulta devuelve cero filas **sin error**: `problem` queda `nil`, `source_last_count_notes` queda en 0, y la UI muestra "Last read: 0 items · <fecha>". Falla silenciosa de la peor clase. Lo correcto es resolver el `Z_ENT` por nombre desde `Z_PRIMARYKEY`.

### 5.3 Parseo de correo hecho a mano

`LocalMailConnector` implementa su propio desdoblado de headers (:80-85), su propio parser de fechas con dos formatos RFC (:106-115), su propio decodificador MIME que solo entiende `=?utf-8?Q?` (:117-122) y su propio limpiador de HTML por regex (:124-133). Consecuencias verificables: asuntos con `=?ISO-8859-1?B?` (Base64 o charset distinto) quedan con los marcadores crudos visibles; fechas en formatos no cubiertos caen al `modificationDate` del archivo, lo que desplaza el mensaje en el tiempo; quoted-printable solo se resuelve parcialmente (`=3D` y saltos, nada más).

### 5.4 Duplicación del `Reading`/problema

Cada conector define su propio `Reading` con un `problem: String?` y su propia frase de Full Disk Access. `LocalMailConnector.swift:36` y `:39` repiten la misma cadena literal completa. `BrowserHistory.describe(_:browser:)` (:210-218) genera una tercera variante. Un cambio de redacción exige tocar 3-4 archivos.

### 5.5 Un solo panel de estado para dos controladores de captura

`CaptureStatusPanel` está tipado contra `AudioCaptureController` (`:10`, `:45`), incluso con una `private extension AudioCaptureController { var isTranscribing }` (:109-111). `CallCaptureController` tiene el mismo `State` de tres casos pero no tiene panel. Extraer un protocolo `CaptureStateReporting` sería trivial y elimina el duplicado conceptual.

### 5.6 `CGWindowListCreateImage` deprecado

`ScreenCapture.captureScreen()` (:125-130) usa la API deprecada en lugar de ScreenCaptureKit, que el proyecto **ya usa** en `SystemAudioCapture`. Deuda con fecha de vencimiento marcada por Apple.

---

## 6. Fallas y riesgos concretos

### 6.1 Mail.app ausente o vacío
Cubierto correctamente. `read` verifica primero que exista `~/Library/Mail` y devuelve `Reading(messages: [], problem: nil)` (:32-34) — ausencia no es error, no se muestra alarma. Si la carpeta existe pero no se puede listar, devuelve la frase de Full Disk Access (:36, :39). Si se leyó parcialmente, `sawUnreadable` produce un problema distinto (:56-58). **Buen manejo.**

### 6.2 Messages.app / Notes.app ausentes o vacíos
Menos cubierto. Si `chat.db` o `NoteStore.sqlite` no existen, `openCopy`/`openSnapshot` devuelve nil y se reporta un problema — pero el usuario que nunca usó Mensajes ve un mensaje de error cuando la respuesta correcta es "no aplica". No hay la distinción "no existe vs no puedo leer" que sí tiene Mail. Además, para Notes, `Z_ENT = 12` desalineado produce 0 filas **sin problema** (§5.2).

### 6.3 Falta Full Disk Access
Tres caminos independientes, no del todo coherentes entre sí:
- Banner global: `SourceCenterView.swift:12-30` alimentado por `Permissions.fullDiskAccessLikely` (sonda real: abre y lee 1 byte).
- Por fuente: la cadena de problema de cada conector → `source_last_problem_<id>` → `sourceStatusLine` → "… · needs attention".
- Estado verde/naranja: `LocalSourceHealth`, que solo mira existencia de archivo (§4.4).
Riesgo: revocación de FDA después de una sincronización exitosa deja la fila en verde hasta la próxima corrida.

### 6.4 Modelo Qwen no descargado
Bien cubierto. `QwenASRRuntime.transcribe` exige `inspect(...).isReady` antes de lanzar el subproceso, y `isReady` valida venv + `pyvenv.cfg` + marcador de engine con versión + `__init__.py` real + `config.json` del snapshot + **todos** los shards del `weight_map` + tamaño > 1 MiB tras resolver symlinks (`QwenASR.swift:292-369`). Una descarga interrumpida se detecta. Si no está listo, `VoiceProvider.providerOrder(qwenReady: false)` cae a `[.appleSpeech]` limpiamente. En Intel, `isAvailable` es false por `#if arch(arm64)` (:131-137) y Apple Speech es el único camino — correcto, pero en un Mac Intel con macOS < 26 **no hay ningún proveedor**: `VoiceProvider.Failure.allProviders` con dos mensajes, y `AudioCaptureController` guarda la nota "Voice note awaiting transcription" (:178-184). El audio no se pierde. Aceptable.

### 6.5 Captura de audio del sistema falla a mitad de llamada
**No cubierto.** Ver §4.3: el error se guarda en `failed` y nunca se lee. El usuario descubre el problema al leer la transcripción. Es el riesgo más serio del subsistema porque el material perdido no es recuperable.

### 6.6 Colisión de archivo temporal en llamadas
Ver §4.1: `CallCaptureController.finish` normaliza las dos pistas en paralelo y ambas apuntan al mismo nombre temporal constante. Riesgo directo de transcripción incorrecta en el caso de uso principal de la función de llamadas.

### 6.7 Micrófono sin permiso durante dictado
Cubierto: `startRecording` pide Accesibilidad primero cuando va a pegar (:83-89) y micrófono después (:90-95), con mensajes distintos por cada negativa. `pasteTarget` se limpia en ambos caminos de fallo.

### 6.8 App destino cerrada antes de que termine la transcripción
Cubierto: `finishedRecording` verifica `!target.isTerminated` (:163) y, si no, marca `insertionUnavailable` y avisa "Voice note saved, but dictation could not be inserted." (:175). El texto queda en el portapapeles.

### 6.9 Contenido sensible en el portapapeles
Cubierto parcialmente: se respetan `org.nspasteboard.ConcealedType` / `TransientType` / `AutoGeneratedType`, que es la convención que usan los gestores de contraseñas serios. Una app que no marque el tipo (o un pegado manual de una credencial) sí queda registrado. `SecretGuard.carriesSecret` se aplica a notas en `CorpusRunner.swift:415` pero **no** a los clips del portapapeles.

### 6.10 Presión de disco
`pruneRecordings(olderThan: 30 días)` (`AudioCaptureController.swift:52-62`) corre una vez al arranque (`AppDelegate.swift:367`). Una sesión de semanas sin reiniciar no poda nada. Las imágenes del portapapeles **no** se podan nunca, y se guardan por duplicado (§4.2).

---

## 7. UX faltante

Analizando `SourceCenterView` y `CaptureStatusPanel`, que son toda la superficie de UI del subsistema:

1. **No existe panel de estado para llamadas.** `CaptureStatusPanel` solo acepta `AudioCaptureController` (`:12`, `:45`). Una grabación de llamada corre sin indicador flotante, sin cronómetro, sin botón de detener y sin la línea "Your audio stays on this Mac". Es la captura más larga y más sensible del producto y es la única sin confirmación visible.
2. **Un fallo del stream del sistema no llega al usuario** (§4.3). Como mínimo hace falta pasar `failed` a `CallCaptureController` y de ahí al mensaje del estado.
3. **La fila "audio" no tiene estado** (§4.5): "Manual" fijo, sin permiso de micrófono, sin estado de Qwen, sin `transcription_last_problem`.
4. **La instalación de Qwen no aparece en el Centro de Fuentes.** `QwenASRInstaller.Phase` tiene `installing`, `failed(String)`, `ready(model:)`, `canResume` — información rica que `SourceCenterView` no muestra. Si la instalación falló, el usuario ve transcripciones peores sin saber por qué.
5. **"Connected" verde sin lectura reciente** (§4.4). Falta distinguir "conectado y leído hace 5 minutos" de "conectado según un ajuste de hace tres semanas".
6. **No hay contador de progreso durante la sincronización.** `sourceSyncing` es binario; `corpusStatusLine` da una fase global (gathering/assembling/writing) pero no un "312 de 1200 mensajes".
7. **El backoff de transcripción es opaco.** `sourceStatusLine` muestra "Retry after HH:MM · needs attention" (:1284-1300) pero no dice qué archivo ni por qué falló, aunque `transcription_last_problem` existe.
8. **Nada indica que las grabaciones se podan a los 30 días.** El usuario puede asumir que su audio es permanente.
9. **No hay forma en la UI de apuntar `transcription_folder` a `Vault.recordingsRoot()`**, que es lo que la mayoría querría. No verificado si existe en otra pestaña de ajustes fuera de este alcance.
10. **`CallReviewView` no ofrece reintentar la transcripción** cuando la nota quedó como "Call awaiting transcription"; `AppDelegate.retryTranscription(_:)` (:1260-1283) existe pero no está expuesto desde esa vista.

---

## 8. Cobertura de test real

### 8.1 Lo que sí está cubierto

| Archivo | Tests | Alcance |
|---|---|---|
| `TranscriptionTests.swift` | 30 `@Test` | El bloque más fuerte del proyecto. Chequeo de disco Qwen antes de que exista el support dir (:16), raíz del venv no `bin/bin` (:28), reparación del venv anidado de 0.32.16 (:34), venv parcial eliminado (:49), cachés aisladas dentro de app support (:61), salida de progreso nunca se vuelve transcripción (:74), contenedores macOS normalizados a WAV (:81), grabación silenciosa detectada antes de llamar al modelo (:109); suite de `agreement`/`trustBar` (:140-219); `VoiceProviderTests` (:221-234: `providerOrder`, legibilidad de `Failure.allProviders`); `QwenInstallDiagnosticsTests` (:236-374: detalle de exit 2 preservado, salida acotada, detección de snapshot small/large, modelo seleccionado controla el runtime, instalación interrumpida reanudable, marcador + snapshot incompleto rechazado, índice sin shards rechazado, symlinks de blobs aceptados, runtime placeholder rechazado) con helper `QwenFixture` (:376-460). |
| `BrowserHistoryTests.swift` | 13 `@Test` | Épocas Safari y Chrome, corte por fecha por época, exclusiones aplicadas al leer (:no después), lista pasada vs de fábrica, alcance por substring y subdominio, lista vacía, todos los perfiles de Chrome, carpetas no-perfil ignoradas, visitas sin título descartadas, orden, "cero navegadores no es una falla", frase del permiso denegado (:332). |
| `LocalSourceConnectorTests.swift` | **2** `@Test` | Solo Mail: sigue la versión `V<n>` más nueva sin asumir V10 (:7-18); `Permissions.fullDiskAccessLikely(home:)` acepta un store de Mail legible (:20-29). |
| `CorpusRunnerTests.swift` | 11 `@Test` | Captura apagada gana, pausa sobre el grafo, sin traza cuando está apagado, pausa corta el ensamblado, períodos olvidados, exclusiones llegan al ensamblado, exclusiones de fábrica, recorte de ventana, episodios derivados nunca reingresan. |
| `MicrophonePermissionTests.swift` | 3 `@Test` | Descripciones de uso en Info.plist, build firmado declara Audio Input, el flujo usa la autoridad del recorder. |
| `PermissionHealthTests.swift` | 3 `@Test` | Callback de micrófono concedido es autoritativo, TCC concedido → ready, undetermined/denied nunca ready. |

### 8.2 Lo que no tiene ningún test

Sin archivo de test propio ni cobertura indirecta encontrada:

- `LocalMessagesConnector` — **cero tests**. Incluye la lógica de doble época (:60-62), que es exactamente la clase de bug que `BrowserHistoryTests` sí cubre para Safari/Chrome. Asimetría injustificada.
- `LocalNotesConnector` — **cero tests**. Incluye el `Z_ENT = 12` hardcodeado (§5.2), el riesgo de falla silenciosa más alto del subsistema.
- `LocalMailConnector.parse` — solo se testea `mailRoot`. El parser de headers, `parseDate`, `decodeHeader` y `cleanExcerpt` no tienen ni un caso.
- `LocalSourceHealth` — cero.
- `ClipboardWatcher` — cero (el doble `saveImage` de §4.2 habría muerto con un test).
- `SystemAudioCapture` — cero (`failed` sin lector, §4.3).
- `AudioCaptureController` / `CallCaptureController` / `CallAppDetector` — cero.
- `ScreenCapture` / `CaptureStatusPanel` / `SourceCenterView` / `ServiceProvider` — cero.
- `Capture.mail` / `Capture.message` / `Capture.note` — cero directos; solo tocados de refilón por `CorpusRunnerTests`.

**Lectura del patrón:** la cobertura sigue las cicatrices. Qwen y BrowserHistory tienen 43 tests entre los dos porque fallaron en producción y alguien los blindó. Messages, Notes, portapapeles y todo el camino de llamadas tienen cero porque todavía no rompieron nada visible. Los tres defectos de §4 están, los tres, en zonas sin tests.

---

## Resumen ejecutivo

**Lo mejor del subsistema:** las verificaciones de Qwen son genuinamente reales (filesystem + shards + tamaño + symlinks, `QwenASR.swift:292-369`); la privacidad se aplica al leer, no después (`BrowserHistory.swift:46-76`); `recordSource` solo marca éxito después de commitear (`CorpusRunner.swift:260-261`); los episodios derivados no reingresan al corpus (`:418`); nunca se pierde audio cuando la transcripción falla.

**Lo que hay que arreglar, en orden:**
1. `QwenASR.swift:686` — falta el `\`, temp file constante, colisión real en llamadas.
2. `SystemAudioCapture.failed` — nunca se lee; grabaciones truncadas silenciosas.
3. `LocalNotesConnector` `Z_ENT = 12` — falla silenciosa a 0 notas.
4. `ClipboardWatcher.swift:92-95` — `saveImage` llamado dos veces.
5. Panel de estado para `CallCaptureController`.
6. Extraer un helper único de snapshot SQLite (hoy son 4 implementaciones).
