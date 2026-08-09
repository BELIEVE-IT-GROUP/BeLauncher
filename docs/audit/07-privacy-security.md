# 07 — Privacy / Security / Identity / Licensing / Diagnostics / Install / Update / Permisos

Auditoría de solo lectura. Repo `/Users/mac/Developer/beacon`, HEAD `7eec075 fix: diagnose silent voice recordings`.
Todas las citas son `archivo:línea` sobre el estado en disco al momento de la auditoría.

## Corrección de la premisa del encargo

El brief afirmaba que `Permissions.swift` y `CapabilityHealth.swift` estaban "modificados en esta misma sesión, sin commitear". **Es falso, verificado:**

- `git status --short` → único archivo trackeado modificado: `M Sources/BeLauncher/AppIntents.swift`. El resto son untracked (`audit-ai-layer/`, `audit-native-actions/`, `docs/audit/`, `docs/plan-action-map-v2.md`).
- `git diff --stat HEAD -- Sources/BeLauncher/Permissions.swift Sources/BeLauncher/CapabilityHealth.swift` → **salida vacía**. Ambos archivos en disco son idénticos a HEAD.
- `git show --stat de18ca2` → tocó `Scripts/Info.plist`, `Permissions.swift` (17 líneas), `QwenASR.swift`, `TranscriptionTests.swift`. **`CapabilityHealth.swift` no fue tocado por ese commit.**

Conclusión: el trabajo de "hacer real el TCC de micrófono" está commiteado y estable. No hay cambios en vuelo en este subsistema.

`Scripts/Info.plist:18` declara `CFBundleShortVersionString = 0.32.25` (un release por delante del último tag de commit visible).

---

## 1. Mapa de responsabilidades

### 1.1 Permisos macOS (TCC)

**`Sources/BeLauncher/Permissions.swift`** (190 líneas) — puerta única a TCC. `@MainActor enum Permissions` (`:8-9`), internal (sin `public`), vive en el target de app, no en Core → **no testeable desde `BeLauncherCoreTests`**.

| Miembro | Línea | Firma / comportamiento |
|---|---|---|
| `microphoneRequest` | `:10` | `private static var microphoneRequest: Task<Bool, Never>?` — deduplica prompts concurrentes |
| `accessibilityGranted` | `:12` | `static var accessibilityGranted: Bool { AXIsProcessTrusted() }` |
| `microphoneGranted` | `:14-16` | `static var microphoneGranted: Bool` → `microphoneStatus(for: AVAudioApplication.shared.recordPermission) == .authorized` |
| `microphoneStatus` | `:18-20` | `static var microphoneStatus: AVAuthorizationStatus` |
| `microphoneStatus(for:)` | `:25-34` | `static func microphoneStatus(for permission: AVAudioApplication.recordPermission) -> AVAuthorizationStatus`. Etiqueta externa **`for`**, interna `permission`. Mapea granted/denied/undetermined + `@unknown default: .notDetermined` |
| `requestMicrophone()` | `:36-48` | `@discardableResult static func requestMicrophone() async -> Bool` |
| `requestMicrophoneOnce()` | `:50-73` | `private static func`. Guarda policy, `.accessory → .regular`, `NSApp.activate`, pide permiso solo si `.undetermined`, `defer` restaura `.accessory`, abre Settings si no concedido |
| `openMicrophoneSettings()` | `:75-77` | pane `Privacy_Microphone` |
| `openScreenRecordingSettings()` | `:79-81` | pane `Privacy_ScreenCapture` |
| `fullDiskAccessLikely` | `:85-87` | computed, delega en la versión con `home:` |
| `fullDiskAccessLikely(home:)` | `:89-106` | `static func … (home: String) -> Bool`. Sonda real |
| `openFullDiskAccessSettings()` | `:108-110` | pane `Privacy_AllFiles` |
| `prepareForPermissionPrompt()` | `:112-114` | `NSApp.activate(ignoringOtherApps: true)` |
| `openPrivacyPane(_:)` | `:116-119` | `private`. URL `x-apple.systempreferences:com.apple.preference.security?<pane>` |
| `automationGranted(askUserIfNeeded:)` | `:130-141` | `static func automationGranted(askUserIfNeeded: Bool = false) -> Bool` |
| `openAutomationSettings()` | `:145-149` | pane `Privacy_Automation` |
| `requestAccessibility(reason:)` | `:153-177` | `@discardableResult static func … -> Bool`. NSAlert explicativo → abre Settings. **Siempre `false` si no estaba ya concedido** (`:176`) |
| `pasteToFrontmostApp()` | `:180-189` | Postea ⌘V vía `CGEvent`. `guard accessibilityGranted` en `:181` → **no-op silencioso** |

Dependencias: AppKit, ApplicationServices, AVFoundation, AVFAudio (`:1-4`), y `LocalMailConnector.mailRoot(home:)` (`:91`).

**`Sources/BeLauncher/CapabilityHealth.swift`** (77 líneas) — respuesta viva de la UI a "¿esto va a funcionar ahora?". `@MainActor @Observable final class CapabilityHealth` (`:8-10`).

- `enum State: Equatable { unknown, ready, needsPermission, unavailable }` con `var isReady: Bool` (`:11-18`)
- `private(set) var microphone / screenRecording / accessibility / automation / fullDiskAccess: State = .unknown` (`:20-24`)
- Closures inyectables `microphoneGrantedCheck: @MainActor () -> Bool` y `microphoneRequest: @MainActor () async -> Bool` (`:26-27`), con defaults a `Permissions` en `init` (`:29-38`), que llama `refresh()` (`:37`)
- `func refresh()` (`:40-46`) — los cinco checks
- `@discardableResult func requestMicrophone() async -> Bool` (`:48-53`), `requestScreenRecording()` (`:55-58`), `requestAutomation()` (`:60-65`), `openFullDiskAccessSettings()` (`:67-69`), `@discardableResult requestAccessibility(reason:)` (`:71-76`)

Comentario de cabecera (`:3-7`): *"a stale green check is worse than an honest orange one"*.

### 1.2 Privacidad de captura

**`Sources/BeLauncherCore/Privacy.swift`** (259 líneas) — `public enum Privacy`.

- `PauseReason { notPaused, byHand, untilLater }`. Un caso `sharingScreen` fue **eliminado deliberadamente**, documentado en `:20-26`
- `State { reason, until }` con `isCapturing(at:)` y `summary(at:)`
- `excludedByDefault` (`:71-75`) — 7 bundle IDs de gestores de contraseñas
- `excludedDomainsByDefault` (`:78-82`) — substrings de banca/login
- `isExcluded(bundleIdentifier:url:apps:domains:)` (`:88-96`)
- `Period { from, to }` + `lastHour` / `today` / `afternoon`
- `Forgetting { passages, clips, nodes, warning }`
- `extension Store` (`:158-259`): `privacyState`, `pauseCapture(_:until:)`, `excludedFromCapture()`, `excludedDomains()` / `setExcludedDomains()` (centinela `·empty·`), `whatWouldBeForgotten(_:)`, `forgottenPeriods()` / `rememberForgotten(_:)`, `isForgotten(_:)`, `@discardableResult forget(_:)`

**`Sources/BeLauncherCore/PrivacyCopy.swift`** (431 líneas) — todos los textos de privacidad, separados de la UI para poder testearlos. `PauseChoice`, `Banner`, `banner(for:at:)`, `menuBarTitle/Tooltip`, `remaining(until:at:)`, `ForgetChoice`, `Confirmation` (`cancelIsDefault` siempre `true`), `breakdown(_:)`, `confirmation(period:forgetting:)`, `forgotten(_:period:)`, `forgetFailed(left:)`, y `PrivacyCopy.Brain.Card` / `cards(...)` / `remoteLine` (admite explícitamente que el texto sale del Mac con modelo de embedding remoto).

**`Sources/BeLauncher/PrivacyView.swift`** (464 líneas) — panel SwiftUI: `PauseCard`, `PauseChoices`, `ExclusionList`, `AddRow`, `ForgetBlock` (flujo destructivo de dos puertas), `FlowRow: Layout`, y `@MainActor final class PauseIndicator: NSObject` (`:382-464`) — status item que solo existe mientras la captura está pausada, tick de 30 s.

**`Sources/BeLauncherCore/SecretGuard.swift`** (190 líneas) — `public enum SecretGuard`. Evita que credenciales entren al historial de portapapeles.

- `redactionMark = "[credential omitted]"` (`:13`)
- `tokenPrefixes` (`:16-28`), `blockMarkers` PEM (`:31-37`), `secretWords` (`:84-88`)
- `public static func carriesSecret(_:) -> Bool` (`:54-67`), `public static func redacted(_:) -> String` (`:71-76`), `public static func looksLikeSecret(_:) -> Bool` (`:156-189`)
- internos: `fragments(of:)` (`:79-81`), `namesASecret(_:)` (`:104-125`), `isWordCharacter(_:)` (`:127-129`), `looksOpaque(_:)` (`:136-139`), `credentialsInURL(_:)` (`:145-154`)

Los comentarios `:41-53` y `:92-103` documentan dos fugas reales previas (token en URL de git, `GITHUB_KEY=`) y por qué la tokenización ahora es por construcción y no por lista de puntuación.

### 1.3 Identidad y licencia

**`Sources/BeLauncher/DeviceIdentity.swift`** (35 líneas) — `IOPlatformUUID` vía IOKit; fallback persiste un UUID en **UserDefaults `"belauncher.device.fallback"`**; `name` desde `Host.current().localizedName`.

**`Sources/BeLauncherCore/License.swift`** (102 líneas) — `LicenseIdentity {email, key, deviceID, lastCheck}`; `LicenseDevice {name, since, deviceID?}` + `canBeReleased`; `ActivationOutcome` (`.activated/.invalid/.deviceLimit/.serverError/.unreachable/.rejected(status:)`) + `.message`; `LicenseKey.normalise/isWellFormed` (regex `^BELN(-[A-Z0-9]{4}){3}$`); `LicenseEmail.normalise/isPlausible`; `LicenseGate.revalidateAfter = 30*24*3600` y `shouldRevalidate(lastCheck:now:)` que devuelve **`false` cuando `lastCheck` es nil**.

**`Sources/BeLauncherCore/LicenseClient.swift`** (160 líneas) — `public struct LicenseClient: Sendable` con `Transport` inyectable. `productionBaseURL = "https://supabase.believe-global.com/functions/v1/belauncher_landing_44aa9b_"` (`:24-26`) — es un **prefijo, no un directorio**; `url(for:)` concatena. `activate(email:key:deviceID:deviceName:)` → `validate-license`; `deactivate(...)` → `deactivate-device`; `send(_:body:)` pone `apikey` y `Authorization: Bearer <anonKey>` (`:113-114`), timeout 20 s.
`@MainActor public enum LicenseVault` (`:135-160`): `settingsKey = "license"`, guarda JSON en la tabla `settings` de SQLite, **no en Keychain**; el motivo está escrito en `:121-134` (el prompt de Keychain al cambiar la firma bloquearía el arranque de un agente de barra de menú). `load(currentDeviceID:)` devuelve nil salvo que `identity.deviceID == currentDeviceID`.

**`Sources/BeLauncherCore/Keychain.swift`** (64 líneas) — `public enum Keychain`, `service = "com.belauncher.launcher.secrets"`, `enum Failure: Error { case status(OSStatus) }`. `set(_:for:)` borra y re-agrega con `kSecAttrAccessibleWhenUnlocked`; `get(_:)`, `delete(_:)`, `names() -> [String]`.

### 1.4 Diagnóstico

**`Sources/BeLauncherCore/Diagnostics.swift`** (65 líneas) — `DiagnosticsReport` + `render()`. Incluye `secretNames: [String]` desde `Keychain.names()` y los **valores** de 8 claves de settings en whitelist. El único permiso reportado es `accessibilityGranted` (`:31`). `extension Store.diagnostics(appVersion:systemVersion:accessibilityGranted:)` (`:44-64`), que llama `clips(limit: 100_000).count`.

**`Sources/BeLauncherCore/InstallDiagnostics.swift`** (61 líneas) — dominio distinto (instalación de modelos): `DiskStatus {.enough/.insufficient/.unknown}`, `NetworkFailure {.offline/.serverUnavailable/.badResponse/.other}`, `disk(requiredBytes:freeBytes:)`, `networkFailure(from raw: String)` — **clasifica por substring en minúsculas del texto del error** ("offline", "network", "timed out", "connection refused"), `networkMessage(for:providerName:)`, `diskMessage(requiredBytes:freeBytes:)`.

**`Sources/BeLauncherCore/InstallProgress.swift`** (65 líneas) — `InstallProgressSnapshot {providerID, model, Phase, step, completedBytes, totalBytes, message, updatedAt, fraction}`. `InstallProgressStore.defaultURL()` → `~/Library/Application Support/BeLauncher/install-progress.json`; `load(providerID:from:)`; `save(_:to:)` crea el directorio con `[.posixPermissions: 0o700]` y escribe `.atomic`.

### 1.5 Export / import y actualización

**`Sources/BeLauncherCore/ExportImport.swift`** (107 líneas) — `BeLauncherArchive` (version 1, snippets, workflows, settings, clips opcionales), `ArchiveError`, `ImportSummary`, `Archive.encode/decode`. `Store.exportArchive(includeClipboard:)` filtra 6 claves de settings; `Store.importArchive(_:)` aplica **todas** las settings del archivo vía `setSetting(key, value)` (`:103`).

**`Sources/BeLauncherCore/UpdateCheck.swift`** (54 líneas) — `Release {version, url, notes}`; `defaultFeedURL = "https://files.believe-global.com/apps/belauncher/latest.json"`; `Outcome {.notConfigured/.upToDate/.available/.unavailable}`; `run(feedURL:currentVersion:)` timeout 8 s, `User-Agent: BeLauncher/<v> (macOS)`; `isNewer(_:than:)`.

**`Sources/BeLauncherCore/UpdateInstaller.swift`** (107 líneas) — `expectedTeamIdentifier = "35R4W3WK5T"` (`:20`); `Phase {idle/downloading/verifying/installing/readyToRelaunch/failed}` + `isBusy`; `Failure {notWritable/translocated/badArchive/couldNotMount/notSignedByUs/notNotarized/replaceFailed}` con `description` de cara al usuario; `isTranslocated(_:)`; `teamIdentifier(fromCodesign:)`; `isNotarized(fromSpctl:)` exige `source=Notarized Developer ID`; `verify(codesignOutput:spctlOutput:)`; `installTarget(bundlePath:)`.

**`Sources/BeLauncher/Updater.swift`** (154 líneas) — `@MainActor @Observable final class Updater`. `install(_:)`, `cancel()`, `relaunch()` (`/usr/bin/open -n` + `NSApp.terminate`), `run(_:)` orquestando installTarget → download (`:74-94`) → `hdiutil attach -nobrowse -noverify -plist -mountrandom` → `newApp(in:)` → `verify` → `replaceItemAt` → `readyToRelaunch`. `shell(_:_:)` mezcla stdout+stderr.

### 1.6 Estado

**`Sources/BeLauncherCore/Store.swift`** (487 líneas) — `@MainActor public final class Store`. `defaultPath()` = `~/Library/Application Support/BeLauncher/belauncher.sqlite3`, el init crea el directorio con `[.posixPermissions: 0o700]`; `migrate()` crea snippets, workflows, clips, flows, launches, aliases, settings, action_log, recipe_offers, work_nodes, work_edges, preferences, missions, action_drafts, packs; `setting(_:)` / `setSetting(_:_:)`; `recordClip` (~`:386-407`) rechaza `SecretGuard.carriesSecret(trimmed)` y apps excluidas; `purgeSecrets()` (`:419-433`); `trimClips(retentionDays:maxItems:now:)`.
**"no verificado":** la lectura de este archivo llegó comprimida por el harness; los números de línea de `recordClip` son aproximados y el listado de tablas puede estar incompleto.

**`Sources/BeLauncherCore/Workspaces.swift`** (193 líneas) — `Workspace` / `Placement`, `WorkspaceLayouts.Fit`, `fit(_:displays:runningBundles:)`, `minimumSide = 200`, `isWorthSaving`, `spansEverything`, `clamp`, `Intent.detect`. Los workspaces se guardan como filas de settings con clave `workspace_<nombre en minúsculas>`. **Sin relación con privacidad/seguridad**: está en este lote por accidente de asignación, no por dominio.

---

## 2. Grafo de relaciones

### Quién consulta permisos antes de ejecutar

```
Permissions (Sources/BeLauncher/Permissions.swift)
 ├─ CapabilityHealth.refresh()            CapabilityHealth.swift:41-45   (los 5 checks)
 ├─ SettingsModel :64                     gate de `pasteAfterCopy` → requestAccessibility(...)
 ├─ ScreenCapture.requestScreenRecording  ScreenCapture.swift:125-145    → prepareForPermissionPrompt()
 ├─ SettingsView (VoiceTab) :602-630      Permissions.microphoneStatus == .denied → texto del botón
 ├─ WelcomeView / CapabilityCard :154+    requestSystemPermission() switch sobre capability.kind
 ├─ main.swift :454-475                   modo CLI de diagnóstico de micrófono
 └─ Diagnostics                           solo `accessibilityGranted`, vía SettingsModel :610-622

CapabilityHealth — CUATRO instancias independientes, ninguna compartida:
 ├─ SettingsView.swift:602    @State private var health = CapabilityHealth()   (VoiceTab)
 ├─ WelcomeView.swift:16      @State private var health = CapabilityHealth()
 └─ (más usos en las vistas de onboarding; cada `@State` construye la suya)
```

### Quién consulta el estado de privacidad antes de capturar

| Consumidor | Línea | Qué hace |
|---|---|---|
| `SettingsModel` | `:413-415` | lee `privacyState`, `excludedFromCapture()`, `excludedDomains()` |
| `SettingsModel` | `:434` | `let shouldRun = privacy.isCapturing() && clipboardEnabled` |
| `AppDelegate` | `:683-684` | `guard store.privacyState.isCapturing(), !store.excludedFromCapture().contains(bundleIdentifier.lowercased())` |
| `CorpusRunner` | `:119-131` | `isCapturing` = `graph_enabled` && `privacyState.isCapturing()`; `guard isCapturing` |
| `LocalSourceHealth` | `:23` | `store.privacyState.isCapturing() && hasEvidence ? .connected : .available` |
| `AppDelegate` | `:495` | cuenta de excluidos para el reporte |

**Hueco explícito y admitido en el código:** `SettingsModel.swift:428-432` — *"Nothing else in app reads `privacyState` yet: wave two sources still being […] they should read `store.privacyState` themselves"*. Es decir, la pausa de privacidad **no es un interruptor global**: cada fuente de captura debe acordarse de consultarla, y el propio comentario reconoce que hay fuentes que todavía no lo hacen.

### Licencia en el arranque

`AppDelegate.applicationDidFinishLaunching`: carga `.env` (Application Support + cwd) → `LicenseVault.use(store)` → `license = LicenseVault.load(currentDeviceID: DeviceIdentity.id)` → `guard license != nil else { presentActivation(); return }` → `revalidateLicenseIfDue()` (~`:627-641`, comentario: *"A monthly courtesy check. It can only ever confirm; a failure never locks the app."*).
`anonKey` (`AppDelegate.swift:75-77`) = `environment["BELAUNCHER_SUPABASE_ANON_KEY"] ?? BuildConfig.supabaseAnonKey`; `BuildConfig.swift:7` tiene el placeholder `"__SUPABASE_ANON_KEY__"` sustituido en release.
`ActivationView` / `ActivationModel` (`:7-47`): `canSubmit = LicenseEmail.isPlausible(email) && LicenseKey.isWellFormed(key) && phase != .working`; `activate()` llama `client.activate(email:key:deviceID: DeviceIdentity.id, deviceName: DeviceIdentity.name)` y construye `LicenseIdentity(..., lastCheck: .now)` en `.activated`.

---

## 3. Inventario de permisos TCC

| Permiso | Chequeo del estado real | API de solicitud | Si está denegado | Usage key en Info.plist |
|---|---|---|---|---|
| **Micrófono** | `AVAudioApplication.shared.recordPermission` (`Permissions.swift:15,19,62`). Deliberadamente **NO** combinado con `AVCaptureDevice.authorizationStatus` — motivo en `:22-24` | `AVAudioApplication.requestRecordPermission` (`:65`), envuelto en el baile `.accessory → .regular → .accessory` (`:55-59`) | abre `Privacy_Microphone` (`:71`); UI muestra "Permission needed" (`SettingsView.swift:602-630`) | `NSMicrophoneUsageDescription` (`Info.plist:33-34`) + `NSAudioCaptureUsageDescription` (`:27-28`) |
| **Accesibilidad** | `AXIsProcessTrusted()` (`Permissions.swift:12`) | No hay API de prompt: NSAlert propio → abre `Privacy_Accessibility` (`:157-175`) | `pasteToFrontmostApp()` es **no-op silencioso** (`:181`) | ninguna (macOS no define una) |
| **Grabación de pantalla** | `CGPreflightScreenCaptureAccess()` (`ScreenCapture.swift:125-145`) | `CGRequestScreenCaptureAccess()`, con fallback a abrir Settings | abre `Privacy_ScreenCapture` (`Permissions.swift:80`) | ninguna (macOS no define una) |
| **Automation / Apple Events** | `AECreateDesc(typeApplicationBundleID, "com.apple.systemevents")` + `AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askUserIfNeeded) == noErr` (`Permissions.swift:130-141`) | mismo llamado con `askUserIfNeeded: true` (`CapabilityHealth.swift:61`) | abre `Privacy_Automation` (`:145-149`). Sin el entitlement el flujo *"reporta éxito y no cambia nada"* (`Permissions.swift:121-126`) | `NSAppleEventsUsageDescription` (`Info.plist:25-26`) |
| **Full Disk Access** | **Sonda real** (`Permissions.swift:89-106`): lista `LocalMailConnector.mailRoot(home:)`, si falla intenta abrir `~/Library/Messages/chat.db` o `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` y leer **1 byte** | no existe API de prompt (comentado en `:83-84`) | abre `Privacy_AllFiles` (`:108-110`) | ninguna (macOS no define una) |
| **Calendario** | `EKEventStore.authorizationStatus(for: .event) == .fullAccess` (`CalendarAccess.swift:1-70`) | `requestFullAccessToEvents()`, pedido una sola vez | `lastError` en `CalendarAccess`; **no aparece en `CapabilityHealth`** | `NSCalendarsUsageDescription` (`Info.plist:29-30`) |
| **Notificaciones** | `UNUserNotificationCenter` (`SettingsModel.swift:865-880`) | `requestAuthorization` | — ; **no aparece en `CapabilityHealth`** | no aplica |

Grep de `NS*UsageDescription` en `Scripts/Info.plist`: exactamente **cuatro** — `NSAppleEventsUsageDescription`, `NSAudioCaptureUsageDescription`, `NSCalendarsUsageDescription`, `NSMicrophoneUsageDescription`. No hay claves para Contactos, Recordatorios, Fotos, Reconocimiento de voz ni carpetas Desktop/Documents/Downloads; **no verificado** si alguna ruta del código las necesita (no encontré usos, pero la búsqueda no fue exhaustiva sobre todo el árbol).

`Scripts/BeLauncher.entitlements` declara solo dos claves: `com.apple.security.automation.apple-events` (`:18-19`) y `com.apple.security.device.audio-input` (`:21-22`). El comentario `:5-17` documenta que sin la primera, en build firmado con hardened runtime, los Apple Events se bloquean **antes** de que macOS pregunte nada — no hay prompt y la app nunca aparece en Privacy › Automation.

---

## 4. Variables y estado

### Keychain
- Servicio único: `"com.belauncher.launcher.secrets"` (`Keychain.swift`, constante `service`)
- Clase `kSecClassGenericPassword`, accesibilidad `kSecAttrAccessibleWhenUnlocked`
- Las cuentas las eligen los llamadores en tiempo de ejecución (API keys de proveedores); `names()` las enumera. **No hay lista fija de claves en el código de este subsistema.**

### UserDefaults
- `"belauncher.device.fallback"` — UUID de dispositivo cuando `IOPlatformUUID` no está disponible (`DeviceIdentity.swift`). **Única clave de UserDefaults en el alcance.**

### Tabla `settings` de SQLite (`~/Library/Application Support/BeLauncher/belauncher.sqlite3`, dir 0o700)

| Clave | Escrita en | Contenido |
|---|---|---|
| `license` | `LicenseClient.swift:135-160` (`LicenseVault.settingsKey`) | JSON de `LicenseIdentity` (email, key, deviceID, lastCheck) **en claro** |
| `capture_pause` | `Privacy.swift:158-259` | razón de pausa |
| `capture_pause_until` | ídem | fecha límite |
| `capture_forgotten` | ídem | períodos `from|to` unidos por saltos de línea |
| exclusión de dominios | ídem | lista, con centinela `·empty·` para distinguir "vacío por elección" de "sin configurar" |
| `graph_enabled` | `CorpusRunner.swift:120` | bool |
| `workspace_<nombre>` | `Workspaces.swift` | layout serializado |

### Ficheros
- `~/Library/Application Support/BeLauncher/install-progress.json` — `InstallProgressStore`, dir 0o700, escritura `.atomic`
- `.env` leído desde Application Support y desde el cwd (`AppDelegate`)

### Entitlements de licencia
No hay entitlements de producto ni feature flags derivados de la licencia: la única compuerta es `license != nil` en el arranque. `LicenseGate.revalidateAfter = 30 días`; una revalidación fallida nunca bloquea (`AppDelegate` ~`:627-641`).

---

## 5. Funciones incompletas / stubs / chequeos simulados

**La pregunta central del encargo — ¿queda algún chequeo de permiso o salud hardcodeado/simulado? — se responde: no.** Los cinco checks de `CapabilityHealth.refresh()` (`:41-45`) resuelven a APIs reales del sistema:

| Check | API real |
|---|---|
| micrófono | `AVAudioApplication.shared.recordPermission` |
| pantalla | `CGPreflightScreenCaptureAccess()` |
| accesibilidad | `AXIsProcessTrusted()` |
| automation | `AEDeterminePermissionToAutomateTarget` |
| disco completo | lectura real de 1 byte sobre un fichero protegido |

Grep de `TODO` / `FIXME` / `fatalError` / `not implemented` en los archivos del alcance: **cero coincidencias**. El único `.notImplemented` del repo es un caso de `AXError` en `WindowArranger.swift:185`, no un stub.

Lo que sí queda incompleto:

1. **`CapabilityHealth.State.unavailable`** (`:16`) está declarado y **nunca se asigna**. Caso muerto: la UI no puede distinguir "hardware ausente / feature no soportada" de "falta permiso".
2. **`CapabilityHealth` nunca vuelve a `.unknown`** y no observa cambios de TCC. `refresh()` solo corre en `init` y bajo demanda; únicamente `WelcomeView` lo re-dispara con `NSApplication.didBecomeActiveNotification`. Cambiar un permiso en System Settings con la app abierta deja el resto de la UI en verde obsoleto — exactamente lo que el comentario de cabecera dice querer evitar.
3. **`Permissions.requestAccessibility(reason:)` no puede devolver `true` salvo que ya estuviera concedido** (`:155` vs `:176`). El llamador (`SettingsModel.swift:64`) recibe `false` incluso cuando el usuario acaba de conceder el permiso en Settings; no hay reconsulta.
4. **`fullDiskAccessLikely` es heurística, y el nombre lo admite.** Si Mail no está configurado y no existen ni `chat.db` ni `NoteStore.sqlite`, devuelve `false` (`:100`) aunque FDA esté concedido. Falso negativo silencioso.
5. **`automationGranted()` solo sondea `com.apple.systemevents`** (`:132`). Cualquier flujo que automatice otra app (Finder, Safari, Mail) se reporta verde sin haber sido autorizado para ese destino — y el propio entitlement lo advierte (`BeLauncher.entitlements:15-16`: *"it does not grant access to any particular app — macOS still asks per target"*).
6. **La pausa de privacidad no es global.** `SettingsModel.swift:428-432` reconoce por escrito que hay fuentes de captura que aún no leen `privacyState`.
7. **`LicenseGate.shouldRevalidate(lastCheck:)` devuelve `false` con `lastCheck == nil`** — una licencia sin fecha nunca se revalida.

---

## 6. Deuda técnica

**No hay duplicación entre `Diagnostics` e `InstallDiagnostics`** — la hipótesis del brief no se sostiene: el primero es el reporte de soporte de la app, el segundo clasifica fallos de instalación de modelos. Dominios disjuntos, cero solapamiento de tipos.

La duplicación real está en otro lado:

1. **Cuatro fuentes de verdad de "¿está todo bien?"**: `CapabilityHealth` (TCC), `DiagnosticsReport` (que reporta un único permiso, `accessibilityGranted`, `Diagnostics.swift:31`), `LocalSourceHealth` (`:23`) y el modo CLI de `main.swift:454-475`. Ninguna se alimenta de otra.
2. **`CapabilityHealth` se instancia cuatro veces** (`SettingsView.swift:602`, `WelcomeView.swift:16`, y otras vistas de onboarding). Cada `@State` es un objeto propio con su propio `refresh()`; dos paneles abiertos pueden mostrar estados distintos del mismo permiso.
3. **Desalineación de taxonomía**: `Onboarding.Capability.Kind` tiene **10** casos (`Onboarding.swift:13-24`: accessibility, automation, screen, calendar, notifications, microphone, fullDiskAccess, clipboard, updates, launchAtLogin) frente a los **5** de `CapabilityHealth`. Calendario y notificaciones se muestran en el onboarding pero su salud se calcula por otro camino (`CalendarAccess`, `SettingsModel:865-880`), fuera del objeto que se llama "salud de capacidades".
4. **`Permissions` vive en el target de app** y por tanto no puede ser cubierto por `BeLauncherCoreTests`; los tests que existen compensan **leyendo el texto fuente del archivo** (ver §9), lo cual verifica que ciertas líneas existen, no que hagan lo correcto.
5. **`InstallDiagnostics.networkFailure(from:)` clasifica por substring del texto de error**. Localización del sistema o un cambio de wording en Foundation degradan silenciosamente todo a `.other`.
6. **`Workspaces.swift` no pertenece a este subsistema** y arrastra ruido de alcance.

---

## 7. Fallas y riesgos concretos

1. **Sin sandbox.** `com.apple.security.app-sandbox` **no aparece en ningún `.entitlements`** (grep sobre todo el repo). La app tiene acceso irrestricto a disco y red, limitado solo por TCC. Es coherente con lo que hace (FDA, Apple Events, escaneo de Mail), pero significa que cualquier bug de deserialización o de ejecución de comandos tiene alcance total sobre la cuenta del usuario.

2. **`Store.importArchive(_:)` aplica cualquier clave de settings del archivo** (`ExportImport.swift:103`) sin whitelist, mientras que el export sí filtra 6 claves. Un `.belauncher` de origen ajeno puede escribir la clave `license`, `graph_enabled` o cualquier `workspace_*`. Asimetría export/import explotable con un fichero adjunto.

3. **Licencia en claro en SQLite** (`LicenseClient.swift:135-160`). Es una decisión documentada y con buen motivo (`:121-134`), pero el efecto es que email + clave de licencia + deviceID son legibles por cualquier proceso del usuario. El binding a `deviceID` en `load()` limita la reutilización, no la lectura.

4. **El reporte de diagnóstico filtra información sensible por diseño**: incluye los **nombres** de todas las entradas de Keychain (`Keychain.names()`) y los **valores** de 8 claves de settings (`Diagnostics.swift`). Se exporta a un `.txt` vía NSSavePanel (`SettingsModel.swift:610-622`) pensado para enviarse a soporte. Los nombres de secretos revelan qué proveedores tiene configurados el usuario; los valores de settings no pasan por `SecretGuard.redacted`.

5. **`Keychain.Failure.description` interpola `self` en vez del `OSStatus`** (`Keychain.swift:11-13`): `"Keychain error \(self)"` produce `"Keychain error status(-25300)"` — funciona por accidente, pero el mensaje es ruidoso y el patrón invita a recursión si alguien cambia la conformidad.

6. **`InstallProgressStore.save(_:to:)` es read-modify-write sin bloqueo.** El directorio es 0o700 pero **el fichero JSON no lleva modo explícito** — hereda el umask. Dos instaladores concurrentes pueden pisarse el progreso.

7. **Secretos en logs / shell**: `Updater.shell(_:_:)` mezcla stdout y stderr de `hdiutil`, `codesign` y `spctl`. No pasa por `SecretGuard`. No encontré rutas donde una credencial llegue ahí, pero la barrera no existe.

8. **`UpdateInstaller` verifica firma y notarización parseando texto de CLI** (`teamIdentifier(fromCodesign:)`, `isNotarized(fromSpctl:)` exigiendo literal `source=Notarized Developer ID`). Es la práctica habitual sin `SecStaticCodeCheckValidity`, pero depende del formato de salida de herramientas de Apple; un cambio de wording convierte una verificación en un fallo (fail-closed, aceptable) — y un `spctl` ausente o alterado en un Mac comprometido es un vector, aunque menor porque el atacante ya estaría dentro.

9. **`anonKey` desde `.env` del cwd** (`AppDelegate`): la app lee `.env` del directorio de trabajo. Lanzada desde una carpeta arbitraria, toma la clave de ahí. Impacto bajo (es una anon key de Supabase), pero es una lectura de configuración desde una ruta no controlada.

10. **`pasteToFrontmostApp()` inyecta ⌘V vía CGEvent** (`Permissions.swift:180-189`). Es el uso legítimo del permiso de Accesibilidad, pero conviene registrar que la app tiene la capacidad de sintetizar eventos de teclado en cualquier app del frente.

---

## 8. UX faltante

1. **Fallo silencioso de accesibilidad**: `pasteToFrontmostApp()` hace `return` sin decir nada (`:181`). El usuario activa "pegar automáticamente", no pasa nada, y no hay mensaje. Es la clase exacta de fallo que el comentario de `Permissions.swift:121-126` identifica como "el peor posible".
2. **Automation por destino**: verde global aunque el destino concreto no esté autorizado (ver §5.5). El usuario ve "listo" y el flujo no hace nada.
3. **`fullDiskAccess` en falso negativo** cuando no hay Mail/Messages/Notes: la UI pide un permiso que quizá ya está concedido, sin forma de decir "no puedo determinarlo" — porque `.unavailable`/`.unknown` no se usan.
4. **Salud obsoleta**: solo `WelcomeView` refresca al reactivarse la app. Cambiar un permiso mientras Settings de BeLauncher está abierto deja el check en verde/naranja viejo.
5. **Calendario y notificaciones sin salud unificada**: el onboarding los lista, pero su estado no vive en `CapabilityHealth`; `CalendarAccess.lastError` es el único canal y no está claro que se muestre.
6. **`requestAccessibility` no reconsulta**: tras abrir System Settings y conceder, el usuario tiene que reintentar la acción manualmente; no hay observación ni "ya lo detecté".
7. **Import de archivo sin previsualización**: `importArchive` aplica settings sin mostrar qué va a cambiar (§7.2).
8. **Diagnóstico sin advertencia de contenido**: se exporta un `.txt` con nombres de secretos y valores de settings sin avisar al usuario de lo que está por compartir.

Lo que **sí** está bien resuelto y conviene no romper: `PrivacyCopy` mantiene todos los textos testeables; `ForgetBlock` (`PrivacyView.swift`) usa dos puertas para el borrado destructivo con `cancelIsDefault = true`; `PauseIndicator` (`:382-464`) da señal permanente en la barra de menú mientras la captura está pausada; `UpdateInstaller.Failure` tiene `description` en lenguaje humano para cada modo de fallo.

---

## 9. Cobertura de test real

| Suite | Tests | Qué cubre |
|---|---|---|
| `Tests/BeLauncherCoreTests/LicenseTests` | 17 | normalización de claves/emails, `isWellFormed`, `shouldRevalidate`, outcomes |
| `PrivacyTests` | 21 | pausa, exclusiones, períodos, `whatWouldBeForgotten`, `forget` |
| `PrivacyCopyTests` | 26 | textos, `remaining`, confirmaciones, breakdown |
| `SecretGuardTests` | 19 | prefijos, PEM, `NAME=value`, credenciales en URL, JWT |
| `UpdateCheckTests` | 5 | parseo del feed, `isNewer` |
| `UpdateInstallerTests` | 9 | translocación, team id, notarización, `verify` |
| `IdentityTests` | 17 | — |
| `ModelInstallTests` | 43 | disco, clasificación de red |
| `Tests/BeLauncherAppTests/MicrophonePermissionTests` | 3 | Info.plist trae las dos usage strings y ambos scripts de bundle la copian; entitlements declara `com.apple.security.device.audio-input` y `release-mac.sh` tiene `require_entitlement`; **aserciones sobre el texto fuente** de `Permissions.swift` (contiene `AVAudioApplication.shared.recordPermission`, `AVAudioApplication.requestRecordPermission`, **no** contiene `AVCaptureDevice.requestAccess(for: .audio)`, tiene `private static var microphoneRequest` y las dos llamadas a `setActivationPolicy`) |
| `Tests/BeLauncherAppTests/PermissionHealthTests` | 3 | usa los closures inyectables de `CapabilityHealth` y `Permissions.microphoneStatus(for: .granted/.undetermined/.denied)` |

**Sin ningún archivo de test:** `Keychain.swift`, `Diagnostics.swift`, `ExportImport.swift`, `InstallProgress.swift`, `Workspaces.swift`, `DeviceIdentity.swift`, y la mitad de `Updater.swift` que toca disco (download, mount, replace, relaunch).

Observaciones sobre la calidad de lo que hay:

- **`MicrophonePermissionTests` verifica texto fuente, no comportamiento.** Es una elección defendible (blinda contra la regresión concreta que ocurrió: volver a `AVCaptureDevice`), pero pasa aunque la lógica sea incorrecta, y romperá con cualquier refactor cosmético.
- **`UpdateCheckTests` incluye tests que pegan a la red en vivo** ("the live feed answers and reports an update for an older version"). La suite falla sin conexión o si el feed cambia; no es determinista.
- **`PermissionHealthTests` solo puede cubrir el micrófono**, porque es la única capacidad con inyección. Los otros cuatro checks de `refresh()` llaman APIs estáticas del sistema y son intesteables tal como está escrito.
- Ninguna de las heurísticas de §5 (FDA, automation por destino) tiene test.
