# Auditoría — Subsistema 3: Flows, Shortcuts, App Intents y handlers de sistema

**Alcance:** automatización de múltiples pasos (Flows), puente con Apple Shortcuts.app, Siri/App Intents, y los `BELActionHandler` que tocan archivos, calendario, pantalla y shortcuts. Grupo cubierto directamente (no por agente en background) por límite de concurrencia del orquestador.

**Archivos auditados (14):**
- `Sources/BeLauncherCore/Flow.swift` (123 líneas)
- `Sources/BeLauncherCore/FlowRunner.swift` (55 líneas)
- `Sources/BeLauncher/FlowEditor.swift` (192 líneas)
- `Sources/BeLauncherCore/WorkflowURL.swift` (61 líneas)
- `Sources/BeLauncher/AppIntents.swift` (161 líneas)
- `Sources/BeLauncherCore/ShortcutIndex.swift` (115 líneas)
- `Sources/BeLauncher/Shortcuts.swift` (111 líneas)
- `Sources/BeLauncher/ShortcutActionHandler.swift` (98 líneas)
- `Sources/BeLauncher/FileActionHandler.swift` (58 líneas)
- `Sources/BeLauncher/PDFActionHandler.swift` (41 líneas)
- `Sources/BeLauncher/CalendarAccess.swift` (57 líneas)
- `Sources/BeLauncher/CalendarActionHandler.swift` (51 líneas)
- `Sources/BeLauncher/ScreenActionHandler.swift` (58 líneas)
- `Sources/BeLauncher/QuickNoteEditorView.swift` (49 líneas)

Ninguno de estos 14 está entre los 16 archivos modificados-sin-commit de esta sesión; son código estable en `origin/main` (`de18ca2`).

---

## 1. Mapa de responsabilidades

| Archivo | Capa | Responsabilidad exacta |
|---|---|---|
| `Flow.swift` | Core (dominio) | Modelo `Flow` + enum `FlowStep` (9 casos) + `FlowValidator` — define QUÉ es un flow y si es válido, sin ejecutar nada. |
| `FlowRunner.swift` | Core (dominio) | Traduce `[FlowStep]` → `[LauncherModel.Action]` puros, expandiendo snippets en el momento de ejecución. Sin efectos secundarios propios. |
| `FlowEditor.swift` | App (UI) | Editor SwiftUI para crear/editar un `Flow` paso a paso, incluido `NSOpenPanel` para elegir apps. |
| `WorkflowURL.swift` | Core (dominio) | Construye URLs de "buscar en la web" a partir de plantillas (`{query}`), con allowlist de esquemas. |
| `AppIntents.swift` | App (integración Siri) | 16 `AppIntent` que solo postean `NotificationCenter` — ninguna lógica de negocio vive aquí. |
| `ShortcutIndex.swift` | Core (dominio) | Indexador de bookmarks de navegador y carpetas comunes — **nada que ver con Apple Shortcuts** pese al nombre. |
| `Shortcuts.swift` | App (integración sistema) | Puente real a Shortcuts.app vía `/usr/bin/shortcuts`; guarda mapeos `actionID → shortcutName`; timers locales. |
| `ShortcutActionHandler.swift` | App (adaptador de acción) | Implementa `BELActionHandler` para `shortcuts.run`, con verificación de exit code y nombre. |
| `FileActionHandler.swift` | App (adaptador de acción) | `files.open` / `files.reveal` / `files.move_to_trash` vía `NSWorkspace`/`FileManager`. |
| `PDFActionHandler.swift` | App (adaptador de acción) | `files.extract_pdf_text` vía PDFKit. |
| `CalendarAccess.swift` | App (UI helper) | Wrapper `@MainActor` de `EKEventStore` para UX de preparación de reuniones — NO es un `BELActionHandler`. |
| `CalendarActionHandler.swift` | App (adaptador de acción) | `calendar.upcoming`, wrapper independiente de `EKEventStore`. |
| `ScreenActionHandler.swift` | App (adaptador de acción) | `screen.read_context` / `screen.ocr`, delega en `ScreenCapture` (fuera de este grupo). |
| `QuickNoteEditorView.swift` | App (UI) | Editor SwiftUI minimalista para notas rápidas; no persiste nada por sí mismo. |

---

## 2. Grafo de relaciones (verificado por grep, no por lectura superficial)

```
LauncherModel.perform(.runFlow)          [LauncherModel.swift:721]
        │
        ▼
FlowRunner.plan(flow, snippets:, expander:)   ← única función pública de FlowRunner.swift
        │  (traduce FlowStep → LauncherModel.Action, expande .runSnippet en el momento)
        ▼
[LauncherModel.Action] (.launchApplication, .openURL, .openFile, .copyToClipboard,
                         .runShortcut, .startTimer, .wait, .dismiss)
        │
        ▼ (consumidos en AppDelegate / LauncherModel, fuera de este grupo)
Shortcuts.run(named:) ← para el caso .runShortcut
Timers.schedule(minutes:label:) ← para el caso .startTimer


BELActionRuntime.handler(for: BELActionDefinition)     [BELActionRuntime.swift]
        │  switch definition.kind
        ├─ .native → primer handler no-nil de la cadena:
        │     SystemCommandActionHandler   (fuera de este grupo, ver AUDITORÍA shell-ui)
        │     ?? FileActionHandler
        │     ?? PDFActionHandler
        │     ?? ScreenActionHandler
        │     ?? CalendarActionHandler
        │     ?? ShortcutActionHandler
        ├─ .ai     → BELAIActionHandler (fuera de este grupo)
        └─ .agentic → nil (no implementado — ver §5)
        │
        ▼
BELActionExecutor.execute(definition, input:, capabilities:, confirmed:, handler:)
   [Sources/BeLauncherCore/BELActionExecution.swift]
        │  1. handler.actionID == definition.id, si no → .handlerDoesNotMatch
        │  2. BELActionGate.decide(...) → .allowed | .requiresConfirmation | .blocked(_)
        │  3. si .allowed → handler.perform(input:)
        ▼
BELActionResult(text:, changed:, receipt:)
```

**Definiciones de acción concretas que resuelven a estos handlers** (`BELActionCatalog.swift`, líneas 103–162): `files.open`, `files.reveal`, `files.move_to_trash`, `shortcuts.run`, `screen.read_context`, `screen.ocr`, `files.extract_pdf_text`, `calendar.upcoming`.

### Corrección a una suposición de esta misma sesión

En una fase anterior de esta sesión se creó `Sources/BeLauncherCore/BELActionDefinition.swift` (sin commit) bajo la suposición de que era un contrato aislado "aún no integrado con nada más". Esa suposición es **incorrecta**: es el mismo tipo `BELActionDefinition` que consumen `init?(definition: BELActionDefinition)` en `ShortcutActionHandler`, `FileActionHandler`, `PDFActionHandler`, `CalendarActionHandler` y `ScreenActionHandler` — no existe un segundo tipo con ese nombre (`grep -rn "struct BELActionDefinition"` da un único resultado). El archivo nuevo ES el contrato vivo detrás de `BELActionRuntime`/`BELActionExecutor`/`BELActionGate`, y ya tiene 5 consumidores reales en producción. Cualquier cambio a su forma (casos de `Capability`, `Risk`, `RoutePolicy`, etc.) es un cambio de breaking-change real, no de un tipo huérfano.

---

## 3. Inventario App Intents / Siri (`AppIntents.swift`)

16 `AppIntent` registrados, todos con el mismo patrón trivial: `perform()` solo hace `NotificationCenter.default.post(name:)` en `@MainActor`, sin lógica propia, sin parámetros, `openAppWhenRun = true` siempre.

| Intent | Notification.Name posteado | Frase Siri (en) |
|---|---|---|
| `OpenBrainIntent` | `.openBrain` | "Open the Brain in ⟨app⟩" |
| `ShowClipboardIntent` | `.showClipboard` | "Show clipboard in ⟨app⟩" |
| `OpenBeLauncherSettingsIntent` | `.openSettings` | "Open ⟨app⟩ settings" |
| `RecordVoiceNoteIntent` | `.recordVoice` | "Record a voice note in ⟨app⟩" |
| `DictateIntoCurrentAppIntent` | `.dictate` | "Dictate into the current app with ⟨app⟩" |
| `ReadScreenIntent` | `.readScreen` | "Read my screen with ⟨app⟩" |
| `WriteQuickNoteIntent` | `.quickNote` | "Write a quick note in ⟨app⟩" |
| `RecordCallIntent` | `.recordCall` | "Record a call with ⟨app⟩" |
| `SearchBrainIntent` | `.searchBrain` | "Search my Brain in ⟨app⟩" |
| `UpcomingMeetingsIntent` | `.upcomingMeetings` | "Show upcoming meetings in ⟨app⟩" |
| `StartFocusIntent` | `.focus` | "Start focus in ⟨app⟩" |
| `PrepareMeetingIntent` | `.prepareMeeting` | "Prepare my meeting in ⟨app⟩" |
| `OpenNotesIntent` | `.openNotes` | "Open my notes in ⟨app⟩" |
| `OpenGraphIntent` | `.openGraph` | "Open the Brain graph in ⟨app⟩" |
| `TranscribeLastVoiceIntent` | `.transcribeLastVoice` | "Review voice notes in ⟨app⟩" |
| `OpenLauncherIntent` | `.openLauncher` | "Open ⟨app⟩" |

Todo el módulo está bajo `#if canImport(AppIntents)`, con `BeLauncherShortcuts: AppShortcutsProvider` registrando las 16 frases. **No hay ningún test para este archivo** (confirmado por grep en `Tests/`).

**Riesgo de acoplamiento silencioso:** cada intent depende de que exista un observador de su `Notification.Name` en `AppDelegate` (fuera de este grupo de archivos). Si un observador se elimina o se renombra sin tocar `AppIntents.swift`, el intent sigue "funcionando" desde Siri (no lanza error) pero no hace nada — falla silenciosa, no detectable por tests porque no hay tests de integración Notification → AppDelegate para estos 16 casos.

---

## 4. Inventario Shortcuts / naming

Dos conceptos con nombres que colisionan y **no tienen relación entre sí**:

- **`ShortcutIndex.swift`** — indexador de *bookmarks de navegador* (Chromium/Safari) y carpetas comunes/documentos recientes del Finder. `scan(home:)`, `chromiumBookmarks`/`parseChromium`, `safariBookmarks`, `commonFolders` (deliberadamente evita checks de existencia que dispararían prompts TCC), `recentDocuments(limit:)`. Nada que ver con Shortcuts.app.
- **`Shortcuts.swift`** — el puente real con Apple Shortcuts.app.

**Naming convention real de las Shortcuts mapeadas por acción** (`BELShortcutMapping`, definido en `Sources/BeLauncherCore/BELShortcutMapping.swift`, fuera de este grupo pero referenciado constantemente):
- `BELShortcutMapping.namePrefix = "BEL • "` (línea 21)
- `isWellFormed` exige `shortcutName.hasPrefix(Self.namePrefix)` (línea 25)
- `BELShortcutMapping.validate(_:)` recolecta issues por mapping inválido (línea 30-34)

Esta convención se aplica en dos sitios, con **una asimetría deliberada pero no documentada en ningún comentario**:
- `ShortcutActionHandler.perform` (línea 36-39): SOLO exige el prefijo `"BEL • "` cuando la llamada viene por `actionID` (flujo dirigido por catálogo/IA). Si `BELShortcutActionInput.name` viene informado directamente (flujo "corre este shortcut por nombre libre", usado por Flows vía `Shortcuts.run(named:)`), el prefijo NO se exige.
- Esto es coherente con el propósito de Flows (el usuario elige libremente cualquier shortcut suyo en `FlowEditor`), pero significa que **el mismo handler tiene dos políticas de nombre distintas según el origen de la llamada** — quien lea solo `BELShortcutMapping.isWellFormed` asumirá que el prefijo es obligatorio siempre; no lo es.

**Doble lectura de `UserDefaults` sin caché ni tipo compartido:** tanto `Shortcuts.mappings()` (Shortcuts.swift:23-28) como `ShortcutMappingStore.name(for:)` (Shortcuts.swift:67-73) decodifican independientemente la misma clave `"bel_shortcut_mappings"` con el mismo `JSONDecoder` + `BELShortcutMapping.validate` — código duplicado, no una función compartida. Si un mapping es inválido, **ambos** devuelven silenciosamente `[]`/`nil` en vez de exponer el problema (ver §6, deuda técnica).

---

## 5. Variables y estado

| Estado | Dónde vive | Ciclo de vida |
|---|---|---|
| Mapeos `actionID → shortcutName` | `UserDefaults.standard`, clave `"bel_shortcut_mappings"`, JSON de `[BELShortcutMapping]` | Persistente, sin migración de esquema visible; `saveMapping` reescribe el array completo ordenado por `actionID` cada vez. |
| `Timers.requested` (`Shortcuts.swift:84`) | `static var` en el enum `@MainActor Timers` | Vive mientras el proceso vive; una vez `true`, nunca vuelve a pedir autorización de notificaciones aunque el usuario la revoque manualmente en Preferencias del Sistema durante la sesión — bug potencial de UX, ver §6. |
| `Flow` (id, keyword, title, steps) | Persistido vía `Store` (SQLite, fuera de este grupo) | CRUD confirmado por test `persistence()` en `FlowTests.swift`. |
| `FlowStep` (enum, 9 casos) | En memoria + serializado dentro de `Flow.steps` | Sin versión/migración explícita si se agregan casos nuevos — un `Flow` guardado con un caso viejo que se elimine del enum rompería la deserialización sin manejo de error visible en este grupo de archivos. |
| `quickNoteWindow` (AppDelegate, fuera de grupo pero consumidor directo) | `NSWindow?` reusado | `QuickNoteEditorView` no tiene estado propio persistente — delega el guardado entero a la closure `save:` que le pasa el caller. |

---

## 6. Funciones incompletas / TODOs / deuda técnica

**Sin TODO/FIXME explícitos en el código** (`grep` limpio en los 14 archivos) — la deuda aquí es de diseño, no de marcadores dejados a propósito.

1. **`.agentic` sin implementar en `BELActionRuntime.handler(for:)`.** El switch tiene 3 casos (`.native`, `.ai`, `.agentic`) y `.agentic` devuelve `nil` incondicionalmente (`BELActionRuntime.swift`). Si `BELActionCatalog` llega a definir alguna acción con `kind: .agentic`, `execute()` la resuelve siempre a `.blocked(.unavailable)` — indistinguible de una acción realmente no disponible por capability. No hay ningún catálogo de acciones `.agentic` todavía (confirmado: `BELActionCatalog.swift` solo usa `.native` y, se infiere, `.ai` para `BELAIActionHandler`), así que hoy es deuda latente, no un bug activo.
2. **Doble desserialización de `bel_shortcut_mappings` duplicada** entre `Shortcuts.mappings()` y `ShortcutMappingStore.name(for:)` — mismo bug si uno se corrige y el otro no (ver §4).
3. **Fallo silencioso en mapeos inválidos.** Si `BELShortcutMapping.validate(values)` encuentra CUALQUIER mapping inválido en el array persistido, ambos puntos de lectura descartan el array ENTERO (`return []` / `return nil`), no solo el mapping roto. Un solo shortcut mal migrado deshabilita TODOS los shortcuts mapeados sin ningún mensaje al usuario ni log — solo `Shortcuts.run(named:)` loguea con `NSLog` cuando el `Process` mismo falla al lanzar, no cuando el mapping es inválido.
4. **`Timers.requested` no se reevalúa tras revocación de permiso.** Una vez que `Timers.schedule` pide autorización la primera vez (otorgada o no), `requested` queda `true` para siempre en el proceso — si el usuario revoca notificaciones desde Preferencias del Sistema a mitad de sesión, los timers subsiguientes llaman `fire(minutes:label:)` igual, generando una notificación que el sistema silenciosamente descartará (no hay feedback al usuario de que el timer "corrió" pero no notificó).
5. **`CalendarAccess.swift` vs `CalendarActionHandler.swift`: dos wrappers independientes de `EKEventStore`.** `CalendarAccess` (UI, `@MainActor final class`) es usado para la UX de preparación de reuniones; `CalendarActionHandler` (struct, `BELActionHandler`) es un wrapper separado para `calendar.upcoming`. No comparten código ni una capa común de acceso a `EventKit` — cualquier fix de permisos/errores de EventKit debe aplicarse dos veces. Confirmado por lectura completa de ambos archivos: no hay `import` cruzado ni delegación entre ellos.
6. **Asimetría de naming no documentada** entre llamada por `actionID` vs por `name` libre en `ShortcutActionHandler` (ver §4) — riesgo de que un futuro cambio "simplifique" quitando la rama libre asumiendo que el prefijo siempre aplica, rompiendo Flows.
7. **`FlowEditor.swift` (192 líneas, UI) no tiene ningún test.** Toda la lógica de validación SÍ está testeada (`FlowTests.swift` cubre `FlowValidator` y `FlowRunner` exhaustivamente), pero la construcción de `StepDraft` → `FlowStep` dentro del editor SwiftUI y el flujo de `chooseApplication()` vía `NSOpenPanel` no tienen cobertura — un bug de mapeo `StepDraft → FlowStep` (ej. un campo mal copiado en un caso del enum) no lo detectaría el test suite actual, solo QA manual.

---

## 7. Fallas y riesgos concretos (con escenario)

1. **Escenario — pérdida silenciosa de todos los shortcuts mapeados:** el usuario tiene 5 acciones mapeadas a shortcuts (`BEL • Enviar a Notion`, etc.). Una actualización futura agrega un campo nuevo requerido a `BELShortcutMapping` sin migración; al decodificar el JSON viejo, uno de los 5 falla `isWellFormed` (o el decode entero falla y cae al `guard let ... else { return [] }`). Resultado: los 5 mapeos desaparecen de la UI y de la ejecución sin ningún mensaje — el usuario ve "no shortcuts configured" en vez de un error de migración. Cubre tanto `Shortcuts.mappings()` como `ShortcutMappingStore.name(for:)`.
2. **Escenario — intent de Siri "funciona" pero no hace nada:** un refactor en `AppDelegate` (fuera de este grupo) renombra o elimina el observer de `BELAppIntentNotification.prepareMeeting` sin tocar `AppIntents.swift`. "Hey Siri, prepare my meeting in BeLauncher" sigue respondiendo con éxito (Siri no tiene forma de saber que no pasó nada), el usuario cree que se preparó la reunión y no lo está. No hay ningún test que ligue intents con sus listeners.
3. **Escenario — timer "silencioso":** usuario corre un flow con `.timer(minutes: 50)` dos veces en la misma sesión. La primera vez otorga permiso de notificaciones. A mitad de sesión, revoca notificaciones para BeLauncher desde Preferencias del Sistema (por ejemplo, fatigado de las de "Bloque de enfoque"). El segundo flow con timer sigue "corriendo" (`Timers.requested == true`, salta directo a `fire`) pero el sistema descarta la notificación sin avisarle a la app ni al usuario que el timer terminó — el usuario cree que el timer sigue activo.
4. **Escenario — inyección de nombre de shortcut vía newline (ya mitigado, documentar como control existente, no como falla):** `ShortcutActionHandler.perform` rechaza explícitamente nombres con `\n`, `\r`, `\0` (línea 33) antes de pasarlos como argumento de `Process` — correcto y deliberado, consistente con el comentario "There is no shell, so a name cannot become a command" en `Shortcuts.swift`. Documentado aquí porque es la única superficie de este grupo que toca ejecución de procesos externos con input parcialmente controlado por datos persistidos (`ShortcutMappingStore.name(for:)`), y vale que quede explícito que SÍ está cubierta.

---

## 8. Integraciones

- **Con Core → App boundary:** `Flow`/`FlowStep`/`FlowValidator`/`FlowRunner`/`WorkflowURL`/`BELActionDefinition`/`BELActionHandler`/`BELActionExecutor` viven en `BeLauncherCore` (sin AppKit); `FlowEditor`/`AppIntents`/`ShortcutActionHandler`/`FileActionHandler`/`PDFActionHandler`/`CalendarAccess`/`CalendarActionHandler`/`ScreenActionHandler`/`QuickNoteEditorView`/`Shortcuts` viven en `BeLauncher` (necesitan AppKit/EventKit/PDFKit/UserNotifications/`/usr/bin/shortcuts`). El patrón es consistente en los 14 archivos: Core define contrato y política, App define adaptador concreto.
- **Con `LauncherModel`:** único punto de entrada de ejecución de Flows (`LauncherModel.swift:721`), y único consumidor de `FlowRunner.plan`.
- **Con `SettingsModel`/`SettingsView`** (grupo de archivos modificados sin commit esta sesión, auditado en otro reporte): `SettingsModel.swift:327` llama `Shortcuts.available()` para poblar el picker de nombres de shortcuts. Este es un punto de acoplamiento directo entre este subsistema y el subsistema de Settings — cualquier cambio a la firma de `Shortcuts.available()` afecta a Settings.
- **Con `AppDelegate`:** `AppDelegate.swift:652` también llama `Shortcuts.available()`; `AppDelegate.swift:1327` instancia `QuickNoteEditorView` pasándole la closure `save:` que llama `self?.perform(.writeNote(text:))` — la persistencia real de la nota vive fuera de este grupo, en el manejo de `.writeNote` de `LauncherModel`/`AppDelegate`.
- **Con `ScreenCapture`** (fuera de este grupo): `ScreenActionHandler` delega el 100% del trabajo real a `ScreenCapture.read(whole:)` / `ScreenCapture.recogniseScreen()` / `ScreenCapture.screenRecordingGranted` — este handler es una fachada delgada, sin lógica propia de OCR o permisos.
- **Con `BELActionCatalog`:** único lugar donde se declaran los `BELActionDefinition` concretos (`files.*`, `shortcuts.run`, `screen.*`, `calendar.upcoming`) que estos handlers terminan resolviendo — confirmado línea por línea en §2.

---

## 9. UX faltante

1. **Sin feedback de error visible para mapeos de shortcuts inválidos** (ver §6.3) — Settings debería mostrar qué mapping específico falló y por qué, en vez de una lista vacía.
2. **Sin indicación de que un timer no notificará** cuando el permiso de notificaciones fue revocado a mitad de sesión (ver §6.4 / §7.3) — ideal sería que `Timers.schedule` reconsultara el estado de autorización real en cada llamada en vez de cachear `requested` para siempre.
3. **Sin manejo de UX para Siri intents "huérfanos"** (ver §7.2) — no hay ningún mecanismo (ni test, ni chequeo en runtime) que garantice que las 16 `Notification.Name` de `AppIntents.swift` tengan siempre un listener activo; un audit de consistencia (aunque sea un test que verifique que `NotificationCenter` tiene observadores registrados para cada nombre en un entorno de test) no existe.
4. **`FlowEditor` no expone la distinción de política de naming de shortcuts** (ver §4/§6.6) al usuario: si el usuario escribe a mano un nombre de shortcut sin el prefijo `BEL • ` en un flow, funciona; si intenta mapear esa misma acción por `actionID` en Settings, falla silenciosamente el `isWellFormed` — dos caminos de UI para el mismo concepto con reglas distintas y sin explicación visible de por qué uno exige el prefijo y el otro no.
5. **Sin confirmación/preview antes de `files.move_to_trash`** dentro de este grupo de archivos — el comentario en `FileActionHandler.swift:9-10` deja explícito que la política de confirmación vive en `BELActionExecutor`/`BELActionGate` (fuera de este grupo), lo cual es correcto arquitectónicamente, pero significa que la UX de confirmación real (el diálogo que ve el usuario) depende enteramente de cómo el caller (fuera de este grupo) maneje `BELActionExecutionError.confirmationRequired` — no verificado aquí, a cruzar con el reporte de "Actions"/UI.

---

## 10. Cobertura de test real

| Archivo fuente | Test dedicado | Cobertura real |
|---|---|---|
| `Flow.swift` / `FlowRunner.swift` | `Tests/BeLauncherCoreTests/FlowTests.swift` (140 líneas, 7 `@Test`) | **Alta.** Cubre: orden de planificación, los 9 casos de `FlowStep` (indirectamente, vía `plansInOrder` + `everyStepKind`), expansión de snippets en tiempo de ejecución (no de guardado), skip de snippet faltante, validación completa (`noSteps`, `badURL`, `badTimer` en ambos extremos, `badShortcutName`, `unknownSnippet`), persistencia round-trip contra `Store` real (SQLite, no mock), y un test end-to-end contra `LauncherModel` real. |
| `WorkflowURL.swift` | `Tests/BeLauncherCoreTests/TransformationTests.swift::WorkflowURLTests` + uso indirecto en `StoreTests.swift:97` | **Alta.** Cubre construcción con query normal, casos con caracteres especiales, y explícitamente el rechazo de esquemas peligrosos (`file://`, `javascript:`) — el control de seguridad central de este archivo está testeado directamente. |
| `ShortcutIndex.swift` | Mencionado solo en `SystemCommandTests.swift` (grep positivo, no es su test dedicado) | **Baja/indirecta.** No hay un `ShortcutIndexTests.swift`; la mención es incidental. Sin test directo de `parseChromium`, `safariBookmarks`, ni de que `commonFolders` evite disparar TCC. |
| `Shortcuts.swift` | **Ninguno** | **Nula.** `saveMapping`, `mappings()`, `run(named:)`, `available()`, `Timers` — sin test alguno. Justificable en parte porque `run`/`available` shell-exec a un binario del sistema (difícil de testear sin mock de `Process`), pero `saveMapping`/`mappings()` (lógica pura de `UserDefaults` + JSON) sí serían testeables y no lo están. |
| `ShortcutActionHandler.swift` | **Ninguno** | **Nula.** Ni el rechazo de nombres con `\n`/`\r`/`\0`, ni la asimetría de política de prefijo (§4), ni el manejo de exit code no-cero están cubiertos por test. Es el handler con más superficie de riesgo (ejecuta un proceso externo) y cero cobertura directa — contrasta con `BELActionExecutionTests.swift`, que sí testea el `BELActionExecutor` genérico pero no este handler concreto. |
| `FileActionHandler.swift` | **Ninguno** | Nula en este grupo (posible cobertura indirecta vía tests de `BELActionCatalog`/`BELActionExecution`, no confirmada — no aparece en el grep de archivos que mencionan `FileActionHandler`). |
| `PDFActionHandler.swift` | **Ninguno** | Nula. |
| `CalendarAccess.swift` / `CalendarActionHandler.swift` | **Ninguno** | Nula para ambos — ni siquiera hay un test que documente la duplicación de wrappers de `EKEventStore` (§6.5). |
| `ScreenActionHandler.swift` | **Ninguno** | Nula — aunque delega en `ScreenCapture` (que puede tener sus propios tests fuera de este grupo, no verificado aquí). |
| `AppIntents.swift` / `BeLauncherShortcuts` | **Ninguno** | Nula — consistente con que `#if canImport(AppIntents)` complica el testing y con que cada intent es una línea trivial; pero significa que el riesgo de §7.2 (intent huérfano) es estructuralmente indetectable por el test suite actual. |
| `QuickNoteEditorView.swift` | **Ninguno** | Nula (SwiftUI view sin lógica propia más allá de la closure `save:`, riesgo bajo). |
| `FlowEditor.swift` | **Ninguno** | Nula (ver §6.7). |

**Resumen cuantitativo del grupo:** de 14 archivos, solo 2 (`Flow.swift`+`FlowRunner.swift` comparten `FlowTests.swift`, y `WorkflowURL.swift`) tienen cobertura directa y sustancial. Los 5 `BELActionHandler` concretos de este grupo (`ShortcutActionHandler`, `FileActionHandler`, `PDFActionHandler`, `CalendarActionHandler`, `ScreenActionHandler`) — es decir, el código que efectivamente toca el sistema de archivos, procesos externos, EventKit y captura de pantalla — tienen **cobertura cero** pese a ser la superficie de mayor riesgo/impacto del grupo. `BELActionExecutionTests.swift` (79 líneas) testea el executor/gate genérico, no estos handlers.
