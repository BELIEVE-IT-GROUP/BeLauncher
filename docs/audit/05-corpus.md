# Auditoría 05 — Corpus / Vault / Episodes / TeamBrain / Ingestión

**Alcance:** cómo el conocimiento (documentos, conversaciones, "episodios" de memoria) se ingiere, almacena y estructura para alimentar el Brain de BeLauncher.
**Repo:** `/Users/mac/Developer/beacon` (Swift 6 / SwiftPM, targets `BeLauncherCore` + `BeLauncher`).
**Método:** lectura completa de los 16 archivos asignados + grep de usos reales + lectura de tests. Solo lectura; el único archivo escrito es este.

### Nota de estado del worktree (corrige el brief)
El brief decía "16 archivos del worktree principal con cambios sin commitear sobre `de18ca2`". **No es lo que hay.** `git status --short` devuelve solo untracked:
```
?? audit-ai-layer/  ?? audit-native-actions/  ?? docs/audit/  ?? docs/plan-action-map-v2.md
```
`HEAD = 93775c5`. **Cero archivos tracked modificados.** Todo lo auditado aquí es código commiteado.

### Corrección al enunciado del punto 2
El brief pide "esquema real de `Database.swift`". `Database.swift` **no contiene esquema**: es un wrapper de SQLite3 de 131 líneas sin un solo `CREATE TABLE`. El esquema real vive en `Store.swift:29` (`migrate()`) y `SemanticIndex.swift:166` (`migrateSemanticIndex()`). La sección 2 documenta esos.

---

## 1. Mapa de responsabilidades

### 1.1 `Sources/BeLauncherCore/Database.swift` (131 líneas)
Wrapper delgado sobre la C API de SQLite3. No conoce ninguna tabla.

| Símbolo | Línea | Firma / forma |
|---|---|---|
| `DatabaseError` | 6-16 | `enum { case open(String); case sql(String, String) }` |
| `SQLValue` | 18-23 | `enum: Sendable, Equatable { case text(String); case int(Int64); case double(Double); case null }` |
| `Row` | 25-49 | `struct: Sendable`, accesores `string(_:) -> String`, `int(_:) -> Int64`, `double(_:) -> Double` |
| `Database` | 51+ | `@MainActor public final class` |
| `handle` | 56 | `private nonisolated(unsafe) var handle: OpaquePointer?` |
| `init(path:readOnly:)` | 60 | `public init(path: String, readOnly: Bool = false) throws` |
| `execute(_:_:)` | 77 | `public func execute(_ sql: String, _ values: [SQLValue] = []) throws` |
| `query(_:_:)` | 81 | `public func query(_ sql: String, _ values: [SQLValue] = []) throws -> [Row]` |
| `lastInsertID` | 85 | `public var lastInsertID: Int64` |
| `perform(_:_:collect:)` | 87-130 | privada; prepare → bind → step |

PRAGMAs fijados en el init: `journal_mode = WAL` (L69, solo si no es readOnly) y `busy_timeout = 3000` (L70).
**Dependencias:** solo `SQLite3` + `Foundation`.

### 1.2 `Sources/BeLauncherCore/Episodes.swift` (167)
Define el episodio: un tramo de tiempo, no una fila por evento.

| Símbolo | Línea | Detalle |
|---|---|---|
| `Episode` | 12 | `struct: Sendable, Equatable, Identifiable` — `id/start/end/signals/title` (L47-52) |
| `Episode.Signal` | 15-45 | `at: Date`, `kind: Kind`, `subject: String`, `title: String`. `titleLimit = 240` (L16). El init trunca y pasa por `IndexedPassage.label` (L43) |
| `Signal.Kind` | 17-31 | `file / application / meeting / conversation / clip / note`; `describesWork: Bool { self != .application }` (L30) |
| `Episode.duration` | 62 | `end - start` |
| `Episode.subjects` | 65-70 | subjects ordenados por frecuencia desc, desempate alfabético |
| `Episode.fallbackTitle` | 76-85 | primeros 3 títulos únicos de señales `describesWork`, "y N más" |
| `EpisodeBuilder` | 88 | `enum` |
| `idleGap` | 96 | `25 * 60` s |
| `maximumLength` | 100 | `4 * 60 * 60` s |
| `minimumLength` | 103 | `90` s |
| `minimumSignals` | 107 | `2` |
| `episodes(from:now:)` | 114-135 | ordena, corta por `gap > idleGap \|\| span > maximumLength` |
| `episode(from:)` | 142-158 | rechaza si <2 señales, si ninguna `describesWork`, o si dura <90 s |
| `isSettled(_:now:)` | 164-166 | `now - episode.end > idleGap` |

**ID determinista** (L153-155): `"episode:" + Semantic.digest("\(Int(first.at.timeIntervalSince1970))|" + subjects.sorted().joined(","))` truncado a 16. Reensamblar las mismas señales produce el mismo id → sin duplicados.
**Dependencias:** `Semantic.digest`, `IndexedPassage.label`, `L(...)`.
**Usos reales:** `Corpus.swift`, `Distillation.swift`, `GraphView.swift`, `SettingsModel.swift`; tests `EpisodeTests`, `CorpusFilesTests`, `CorpusRunnerTests`.

### 1.3 `Sources/BeLauncherCore/Corpus.swift` (723)
El núcleo de ensamblado: señales heterogéneas → episodios → entidades → items indexables.

| Símbolo | Línea | Detalle |
|---|---|---|
| `Corpus` | 18 | `episodes / considered / entities / proposals / items / isPaused` |
| `Corpus.Considered` | 26-44 | por qué un episodio entró o no (explicación en palabras) |
| `Corpus.indexed` | 69 | los que sí entran |
| `.empty` / `.paused` | 71 / 72 | constructores |
| `BrowserVisit` | 82 | `subject` = host + primer segmento de path (L101-108) |
| `MailMessage` | 113 | — |
| `MessageRecord` | 139 | — |
| `NoteRecord` | 158 | — |
| `Transcript` | 173 | — |
| `CorpusBuilder` | 190 | `enum` |
| `CorpusBuilder.Input` | 194-242 | nodes, clips, exchanges, visits, mails, messages, notes, transcripts, forgotten, privacy, excludedApps, excludedDomains, rejectedMerges, markedByHand, now, calendar |
| `entityLimit` | 249 | `400` |
| `assemble(_:)` | 252-285 | pipeline completo (ver §3) |

Productores de señal: `signals(fromNodes:)` L304-314 (salta ids con prefijo `episode:`, L309 — evita realimentación), `signalKind(for:)` L316-325, `signals(fromClips:)` L329, `signals(fromExchanges:)` L343, `signals(fromVisits:)` L355, `signals(fromTranscripts:)` L381.
Listas de admisión: `allowedMails` L363, `allowedMessages` L371 (mínimo 40 chars), `allowedNotes` L377, `allowedNodes` L394, `allowedClips` L402, `allowedTranscripts` L416, `allowedExchanges` L420, `allowedVisits` L446. `machineMarkers` L436-439 + `isMachineWritten` L441 descartan texto que escribió la máquina.
Puntuación y plegado: `weigh` L460-483 (`daysSeen`, vecinos, `markedByHand`, gate `isSettled` L476), `daysPerSubject` L486, `fold` L500-555, `path(for:)` L565-570, `resolve` L573-603 (**bucle par-a-par cuadrático**), `coOccurrence` L606-624.
Constructores de item: episodio L634-662, transcript L664, mail L674, message L688, note L698.
`MailRelevance` L708-723: `workCues` L709, `isWorthIndexing` L718.
**Usos:** `CorpusRunner.swift`, `CorpusFiles.swift`, `GraphView.swift`; tests `CorpusTests`, `PrivacyTests`, `CorpusRunnerTests`, `GraphCorrectionsTests`.

### 1.4 `Sources/BeLauncherCore/CorpusFiles.swift` (829)
El corpus como archivos Markdown editables a mano + el escritor de carpeta con staging.

| Símbolo | Línea | Detalle |
|---|---|---|
| `CorpusDocument` | 20 | documento portable |
| `CorpusDocument.Kind` | 22-45 | `episode / entity / statement`; `folder` L30, `label` L38 |
| `CorpusDocument.Corrections` | 52-91 | `pinned`, `hidden`, `mergedInto`, `rejectedMerges`, `markedSubjects`, `editedByHand`, `editedAt`; `isEmpty` L87 |
| `CorpusFiles.folders` | 132 | carpetas del corpus |
| `machineRead` | 139 | qué carpetas relee la máquina |
| `readme` | 141-171 | texto de `LÉEME — corpus.md` |
| `document(for episode:)` | 176-200 | — |
| `document(for entity:)` | 207-225 | — |
| `entity(from:)` | 228-234 | — |
| `document(for statement:)` | 241-255 | — |
| `Correction` | 260-270 | `enum` de correcciones aplicables |
| `apply(_:to:)` | 272-298 | — |
| `handEdit` | 301-315 | — |
| `rejected(in:)` | 318 | — |
| `Learned` | 335-353 | lo aprendido de las correcciones del usuario |
| `learned(in:)` | 355-368 | desde documentos ya cargados |
| `learned(inFolderAt:)` | 375-389 | **lee disco fuera del MainActor** |
| `hidden(in:)` / `pinned(in:)` | 391 / 395 | — |
| `Write` | 401-408 | resultado de una escritura |
| `write(_:over:)` | 416-429 | edición a mano gana; correcciones se arrastran; rename preservado (L424-426) |
| `reservedKeys` | 434 | — |
| `render(_:)` | 439-476 | Markdown + front matter YAML a mano |
| `parse(_:)` | 482-532 | rechaza front matter que no sea de corpus |
| `wikilink` / `links(in:)` | 535 / 545 | — |
| `handle(for:)` / `filename(for:)` / `relativePath` | 564 / 568 / 575 | — |
| `CorpusFolder` | 614-829 | `@MainActor public final class` |

`CorpusFolder`: `StagedWrite` L616, `StagingManifest` L622, `init(root:manager:)` L629-643 (crea carpetas con permisos `0o700`, llama `recoverStaging()` L637, escribe el LÉEME L639), `defaultRoot()` L645 → delega en `Vault.defaultRoot()`, `existingPath(for:kind:)` L656, `paths(for:kind:)` L662-672, `save` L676-687, `saveBatch` L694-731, `saveHandEdit` L736, `apply` L745, `force` L752-758, `publish` L760-775, `recoverStaging` L777-795, `load` L797, `documents(kind:)` L803-823, `delete` L825.
**Usos:** `CorpusRunner.swift`, `CorpusReaderView.swift`, `GraphView.swift`, `AppDelegate.swift`; tests `CorpusFilesTests`, `GraphCorrectionsTests`.

### 1.5 `Sources/BeLauncherCore/Vault.swift` (384)
La bóveda: objetos de memoria (`MemoryObject`) en disco, commits, evidencia, auditoría IA.

| Símbolo | Línea | Detalle |
|---|---|---|
| `Vault` | 11 | `@MainActor public final class` |
| `StagedWrite` / `StagingManifest` | 12 / 18 | **duplicado exacto conceptual de `CorpusFolder`** |
| `init(root:)` | 25-35 | crea `objects/commits/attachments/inbox/audit`, `recoverStaging()` L31, `VaultGuide.scaffold` L34 |
| `defaultRoot()` | 37 | raíz por defecto |
| `recordingsRoot()` | 43 | — |
| accesores de carpeta | 48-52 | — |
| `recordAIAudit` | 56-64 | **lee entero `audit/ai.jsonl` y lo reescribe por cada evento** |
| `aiAuditEvents` | 66-74 | — |
| `saveEvidence` | 80-92 | — |
| `saveQuickNote` | 95-103 | — |
| `save(_ object: MemoryObject)` | 107-123 | — |
| `path(forID:)` | 126-135 | **escaneo lineal + parseo de todos los archivos** |
| `load(id:)` | 137 | llama a `objects()` (O(n)) |
| `objects()` | 141-151 | — |
| `current(kind:at:)` | 154 | — |
| `backlinks(to:)` | 162-167 | — |
| `delete(id:)` | 169 | — |
| `filename(for:)` | 174 | usa `Importers.slug` |
| `save(_ commit:)` | 183 | — |
| `commits(state:)` | 192 | — |
| `propose` | 210-221 | — |
| `confirm(commitID:at:)` | 226-263 | — |
| `discard` | 265 | — |
| `overlaps` | 280-296 | bag-of-words; umbral 0.4 con entidad compartida, 0.7 sin ella |
| `writeFiles` | 309-333 | — |
| `publish` | 335-353 | — |
| `recoverStaging` | 355-372 | — |
| `ISO8601DateFormatter.vaultStamp()` | 379 | — |

**Usos:** `TeamBrain.swift`, `CorpusFiles.swift`, `Pulse.swift`, MCP; tests `VaultTests` (40), `MCPToolsTests`, `MCPHealthTests`, `AgentTests`.

### 1.6 `Sources/BeLauncherCore/VaultDocument.swift` (121)
Serialización Markdown+YAML de `MemoryObject`. `render(_:)` L10-37, `parse(_:)` L39-86, helpers `quote` L90, `unquote` L98, `list` L105, `iso` L113, `date` L117. **`CorpusFiles.render/parse` reutiliza estos helpers escalares** — es el único puente entre los dos modelos de documento.

### 1.7 `Sources/BeLauncherCore/VaultGuide.swift` (178)
Scaffolding humano de la bóveda. `folders` L17-25 (`objects, commits, attachments, people, projects, meetings, inbox`), `readme` L30, `machineRead = ["objects","commits"]` L83, `gitignore` L87-92, `readmeName = "LÉEME.md"` L101, `scaffold(at:manager:)` L105-132 (deja `QUÉ VA AQUÍ.md` en carpetas no machine-read, L120), `obsidianURL(for:)` L135, `GitResult` L144, `makeGitRepository` L152-166, `runGit` L168.

### 1.8 `Sources/BeLauncherCore/TeamBrain.swift` (272)
Compartir la bóveda entre personas, cifrado.

| Símbolo | Línea | Detalle |
|---|---|---|
| `Role` | 13-33 | `reader / editor / owner`; `canConfirm` L31, `canManageMembers` L32 |
| `Member` | 35 | — |
| `Bundle` | 49-86 | `currentVersion = 1`; objects, members, packs, flows, snippets, standards |
| `ShareError` | 88-106 | — |
| `sharedMarker = "shared"` | 112 | — |
| `shareable` | 114 | — |
| `key(fromPassphrase:team:)` | 125-129 | **`SHA256.hash(passphrase + salt)` — un solo hash, sin PBKDF2/HKDF/scrypt** |
| `seal` | 131 | AES.GCM |
| `open` | 140-164 | — |
| `MergeResult` | 168-178 | — |
| `topics(of:)` | 182 | — |
| `CommandMerge` | 193-200 | — |
| `planCommands` | 206-239 | — |
| `plan(_:against:)` | 246-271 | — |

**Usos:** `SettingsModel.swift`, `Vault.swift`, `Pulse.swift`; tests `TeamBrainTests` (12), `AgentTests`.

### 1.9 `Sources/BeLauncherCore/Distillation.swift` (139)
Destilado nocturno con LLM: episodios → afirmaciones citadas.
`Statement` L16-30 (`id = "statement:" + digest(text + sources)`), `minimumEpisodes = 2` L44, `prompt(for:)` L55-75 (system prompt en inglés, episodios numerados, `[n]` obligatorio), `parse` L83-99 (**descarta toda línea sin cita válida**; exige `valid.count == cited.count` L92), `citations` L101, `strip` L117, `ready` L135-138.

### 1.10 `Sources/BeLauncherCore/IngestionCheckpoint.swift` (36)
`Phase`: `gathering / assembling / writing / completed` (L9). Campos `id / source / windowStart / updatedAt / phase / completed` (L14-18). `canResume(source:)` L33-35 = `!completed && source == requestedSource`. `Codable`, se persiste como JSON en el setting `corpus_checkpoint`.

### 1.11 `Sources/BeLauncherCore/IngestionProgress.swift` (36)
`Phase`: `waiting / gathering / assembling / writing / completed / paused / deferred / failed` (L6). Campos `runID / source / phase / completedItems / totalItems / writtenPassages / problem / updatedAt` (L11-17). `fraction` L32-35 (nil si `totalItems == 0`). Persistido en `corpus_ingestion_progress`.

### 1.12 `Sources/BeLauncher/CorpusRunner.swift` (758)
El orquestador. Único punto que hace correr toda la ingestión.

| Símbolo | Línea | Detalle |
|---|---|---|
| `CorpusRunRecord` | 5-15 | `id / startedAt / finishedAt / source / phase / written / problem` |
| `CorpusRunner` | 34-36 | `@MainActor @Observable final class` |
| `RunResult` | 37-43 | `completed / paused / deferred / busy / failed` |
| `Phase` | 45-47 | — |
| estado | 49-64 | `store`, `weak brain: BrainSearch?`, `ask` closure, `loop: Task<Void,Never>?`, `phase`, `isRunning`, `lastRun`, `lastWritten`, `lastProblem`, `lastDeferral`, `runHistory`, `checkpoint`, `currentRunID`, `currentRunSource` |
| `interval` | 70 | `.seconds(30*60)` |
| `warmUp` | 74 | `.seconds(90)` |
| `window` | 78 | `36*60*60` |
| `init` | 80-96 | restaura `corpus_checkpoint` (solo si `!saved.completed`) y `corpus_run_history` |
| `start()` / `stop()` | 100-110 / 112-116 | — |
| `isCapturing` | 119-121 | `store.setting("graph_enabled", default: false) && store.privacyState.isCapturing()` |
| `runOnce(source:now:ignoringPowerPolicy:)` | 128-293 | la pasada completa (ver §3) |
| `powerSource()` | 297-314 | IOKit |
| `recordRun` | 316-325 | guarda 20 |
| `recordSource` | 327-343 | backoff `min(24h, 30min * 2^(n-1))` L333 |
| `sourceMayRun` | 347-352 | — |
| `setPhase` | 354-361 | — |
| `persistIngestionProgress` | 363-377 | → setting `corpus_ingestion_progress` |
| `persistCheckpoint` | 379-390 | → setting `corpus_checkpoint` |
| `assemblyInput` | 404-429 | nodes ≤2000, clips ≤500; inyecta `forgotten` L424 y `rejectedMerges`/`markedByHand` L427 |
| `write(_ corpus:)` | 440-547 | escritura al índice y al grafo (ver §3) |
| `workNodeExists` | 551 | — |
| `when(_:)` / `graphKind(for:)` | 555 / 562-569 | — |
| `conversations(since:limit:40)` | 578-600 | recorre `.jsonl` de `~/.claude/projects` filtrando por mtime |
| `transcribePending(since:)` | 610-657 | carpeta opt-in `transcription_folder`; ledger `transcribed_files` (tope 500); **`break` tras un solo archivo por pasada, L652** |
| `distillIfDue(now:calendar:)` | 666-715 | setting `distilled_day`, `BackgroundRunPolicy.isOvernight` |
| `learned` | 720 | — |
| `refreshCorrections(root:)` | 730-734 | — |
| `rejectedMerges()` | 744-747 | unión con setting legado `corpus_rejected_merges` |
| `markedByHand()` | 754-757 | unión con `sourceApp` de clips pinneados |

### 1.13 `Sources/BeLauncher/CorpusReaderView.swift` (416)
Lector/editor del corpus. `CorpusReaderModel` L14-105 (`query`, `kind`, `selectedID`, `isEditing`, `draft`, `status`, `documents`; `reload` L31, `results` L42-52 — match exacto de fold y luego fuzzy —, `follow` L65-74, `beginEditing/cancelEditing/save` L76-99, `revealInFinder` L101). `CorpusReaderView` L108-307 (HSplitView, campo de búsqueda, picker de Kind, iconos pinned/editado-a-mano L189-196, cabecera con Edit/Save/Discard/Finder L247-286, TextEditor L288-299). `Tag` L310-330. `MarkdownBody` L338-416 con `pieces(of:)` L403-415.

### 1.14 `Sources/BeLauncherCore/Conversations.swift` (137)
Ingestión de sesiones de Claude Code. `Exchange` L14-30, `sessionsFolder(home:)` L33 → `~/.claude/projects`, `minimumQuestion = 25` L38, `answerLimit = 600` L41, `exchanges(inLines:)` L47-79 (JSONL línea a línea, salta `isSidechain`, salta tool results L67, empareja pregunta con la siguiente respuesta), `readable` L86-95 (quita bloques de thinking), `isToolResult` L97, `timestamp` L103, `items(from:)` L113-126, `ISO8601DateFormatter.withFractionalSeconds()` L132.

### 1.15 `Sources/BeLauncherCore/Inbox.swift` (50)
Tipo de proyección puro, **sin lógica de ingestión**. `InboxItem` L5-50, `Kind` `note/evidence/clipboard` L6-11, `State` `pending/needsTranscription` L12-15, `init(record: QuickNote.Record)` L27, `init(clip: Clip)` L39. Usado solo por `GraphView.swift` y `UtilitiesTests`.

### 1.16 `Sources/BeLauncherCore/Importers.swift` (160)
Importadores de snippets de terceros. `Result` L10-15, `alfredSnippetsFolder` L19, `parseAlfredSnippet` L25-37, `importAlfredSnippets` L39-55, `parseRaycastExport` L60-94, `convertPlaceholders` L100-118, `slug` L121-130 (**usado tanto por `CorpusFiles.filename` como por `Vault.filename`**), `extension Store { apply(_:) }` L133-160. Rigurosamente hablando no es parte del pipeline de corpus; entra por `slug`.

---

## 2. Modelo de datos

**Motor:** SQLite3 crudo vía la C API, un solo archivo en `~/Library/Application Support/BeLauncher/belauncher.sqlite3` (`Store.swift`, cerca de L25). WAL activado en `Database.swift:69`, `busy_timeout = 3000` en L70. `main.swift:30,33` fuerza `PRAGMA wal_checkpoint(TRUNCATE)` al cerrar.
**No hay versionado de esquema.** No existe `PRAGMA user_version` en ninguna parte del repo; la migración es `CREATE TABLE IF NOT EXISTS` + `try? ALTER TABLE` que ignora el error (`Store.swift:63-67`). Ver §6.

### 2.1 Esquema base — `Store.swift:29` `migrate()`

| Tabla | Línea | Columnas |
|---|---|---|
| `snippets` | 31 | `id INTEGER PK AUTOINCREMENT, keyword TEXT UNIQUE, title TEXT, body TEXT, uses INTEGER DEFAULT 0, created_at REAL` |
| `workflows` | 41 | `id PK AUTOINCREMENT, keyword TEXT UNIQUE, title TEXT, url_template TEXT, uses INTEGER, created_at REAL` |
| `clips` | 51 | `id PK AUTOINCREMENT, text TEXT, digest TEXT UNIQUE, source_app TEXT DEFAULT '', created_at REAL, kind TEXT DEFAULT 'text', pinned INTEGER DEFAULT 0, asset_path TEXT DEFAULT ''` |
| (migración de columnas) | 63-67 | `ALTER TABLE clips ADD COLUMN` para `kind`, `pinned`, `asset_path`, envuelto en `try?` |
| `flows` | 69 | `id PK AUTOINCREMENT, keyword TEXT UNIQUE, title TEXT, steps TEXT, uses INTEGER, created_at REAL` |
| `launches` | 79 | `path TEXT PK, uses INTEGER, last_used REAL` |
| `aliases` | 86 | `alias TEXT PK, target TEXT` |
| `settings` | 92 | `key TEXT PK, value TEXT` ← **aquí vive todo el estado de ingestión** |
| `action_log` | 101 | `id PK AUTOINCREMENT, signature TEXT, label TEXT, at REAL`; índice `action_log_at (at)` L108 |
| `recipe_offers` | 112 | `key TEXT PK, accepted INTEGER, at REAL` |
| `work_nodes` | 121 | `id TEXT PK, kind TEXT, name TEXT, detail TEXT DEFAULT '', target TEXT DEFAULT '', lastSeen REAL, weight INTEGER DEFAULT 1` |
| `work_edges` | 132 | `source TEXT, target TEXT, kind TEXT, at REAL, PK(source,target,kind)` |
| índice | 140 | `work_nodes_seen (lastSeen)` |
| `preferences` | 144 | `trait TEXT PK, value TEXT, confidence REAL, observations INTEGER, updatedAt REAL` |
| `missions` | 155 | `id TEXT PK, intent TEXT, state TEXT, payload TEXT, createdAt REAL, updatedAt REAL` |
| `action_drafts` | 165 | `id TEXT PK, intent TEXT, payload TEXT, createdAt REAL, updatedAt REAL` |
| `packs` | 176 | `id TEXT PK, payload TEXT, installedAt REAL, source TEXT DEFAULT ''` |

Acceso a settings: `setting(_:) -> String?` L187, sobrecargas con default Bool L192 / Int L196, `setSetting` L200/207/208.

### 2.2 Índice semántico — `SemanticIndex.swift:166` `migrateSemanticIndex(repairOversizedTitles:)`
Separado a propósito: es dato derivado y se puede tirar y reconstruir entero.

```sql
CREATE TABLE IF NOT EXISTS passages (
    id           TEXT PRIMARY KEY,          -- "\(source.key)#\(ordinal)"
    source_key   TEXT NOT NULL,
    source_kind  TEXT NOT NULL,             -- IndexedSource.Kind.rawValue
    title        TEXT NOT NULL DEFAULT '',
    ordinal      INTEGER NOT NULL DEFAULT 0,
    text         TEXT NOT NULL,
    occurred_at  REAL NOT NULL,
    digest       TEXT NOT NULL,             -- Semantic.digest(boundedText)
    vector       TEXT,                      -- base64, NO blob (comentario L~176)
    vector_model TEXT NOT NULL DEFAULT ''
)
```
Índices: `passages_source (source_key)` L185, `passages_kind (source_kind)` L186, `passages_when (occurred_at DESC)` L189.
FTS: `CREATE VIRTUAL TABLE passages_fts USING fts5(text, title, content='passages', content_rowid='rowid', tokenize="unicode61 remove_diacritics 2")` L194. Triggers `passages_ai` (AFTER INSERT), `passages_ad` (AFTER DELETE), `passages_au` (AFTER UPDATE) mantienen el índice de palabras sin que ningún código tenga que acordarse.

`IndexedSource.Kind` (SemanticIndex.swift:10-32): `memory / node / clip / note / conversation`.
Límites: `IndexedPassage.titleLimit = 160` (L78), `IndexedPassage.sourceTextLimit = 1_000_000` (L81).

**`replacePassagesChecked(for:title:occurredAt:text:)`** (L478+): trunca a `sourceTextLimit`, corta en pasajes con `Semantic.passages`, calcula digest; **si el digest coincide con el existente y el corte no está vacío, devuelve `[]` sin tocar nada** (evita reembeber lo que no cambió). Si cambió: `BEGIN IMMEDIATE` → `DELETE FROM passages WHERE source_key = ?` → N `INSERT` → `COMMIT`, con `ROLLBACK` en el catch. `replacePassages` (L~466) es el wrapper que se traga el error con `try?` — **el runner usa la variante `Checked`** (`CorpusRunner.swift:443`).

### 2.3 Formato real de un episodio
Tres representaciones simultáneas del mismo episodio:
1. **En memoria:** `Episode` (Episodes.swift:12) con sus `Signal`.
2. **En SQLite:** una fila en `passages` con `source_kind = 'node'` y `source_key` derivado del id `episode:<digest16>`; más un nodo en `work_nodes` y aristas `.cameFrom` / `.workedWith` / `.partOf` en `work_edges` (escritas en `CorpusRunner.write` L508-536).
3. **En disco:** un `.md` con front matter YAML en la carpeta de corpus (`CorpusFiles.render` L439-476), editable a mano.

### 2.4 Formato de un documento de Vault (`MemoryObject`, `Memory.swift:8`)
`Codable, Sendable, Equatable, Identifiable`. Campos:
`id: String`, `level: Level`, `kind: Kind`, `statement: String` (una frase), `body: String`, `source: String`, `owner: String`, `createdAt: Date`, `validFrom: Date`, `validUntil: Date?`, `confidence: Double`, `status: Status`, `supersedes: [String]`, `supersededBy: String?`, `entities: [String]`, `evidence: [String]`.
- `Level` (L10-19): `evidence / extracted / committed / outcome` — **solo `committed` se considera verdad**.
- `Kind` (L21-30): `decision / commitment / policy / definition / learning / note / person / project`.
- `Status` (L32-37): `active / superseded / retired`.
En disco: Markdown + front matter YAML vía `VaultDocument.render/parse`, un archivo por objeto en `objects/`, nombre = `Importers.slug`.

### 2.5 Formato de un item de Corpus
`CorpusDocument` (CorpusFiles.swift:20) con `Kind` `episode / entity / statement` (L22-45), cada uno con su carpeta (L30). Lleva embebido un bloque `Corrections` (L52-91) que es lo que el usuario puede alterar y la máquina debe respetar.

**Dos modelos de documento paralelos, sin tipo común:** `CorpusDocument`/`CorpusFiles` y `MemoryObject`/`VaultDocument`. Ver §6.

### 2.6 Estado de ingestión: no hay tablas, hay filas de `settings`
Todo el estado de ingestión es JSON o texto plano dentro de `settings (key, value)`:

| Key | Escrito en | Leído en |
|---|---|---|
| `corpus_checkpoint` | CorpusRunner.swift:379-390 | CorpusRunner.swift:85-89, SettingsModel.swift:1342-1344 |
| `corpus_ingestion_progress` | CorpusRunner.swift:376 | SettingsModel.swift:1337-1339 |
| `corpus_run_history` | CorpusRunner.swift (recordRun 316-325) | CorpusRunner.swift:91, SettingsModel.swift:1334 |
| `corpus_last_run` | CorpusRunner.swift:277 | SettingsModel.swift:1331 |
| `corpus_last_passages` | CorpusRunner.swift:457 | SettingsModel.swift:1332 |
| `corpus_last_problem` | CorpusRunner.swift:276, 358-360 y ruta de fallo ~256 | SettingsModel.swift:1333 |
| `corpus_merge_questions` | CorpusRunner.swift:542 | **nadie** (ver §8) |
| `corpus_rejected_merges` (legado) | — | CorpusRunner.swift:744-747 |
| `source_retry_after_<id>` | CorpusRunner.swift:327-343 | CorpusRunner.swift:347-352 |
| `graph_enabled` | ajustes | CorpusRunner.swift:119 |
| `transcription_folder` | ajustes | CorpusRunner.swift:610-618 |
| `transcribed_files` | CorpusRunner.swift:655 | CorpusRunner.swift:619 |
| `distilled_day` | CorpusRunner.swift:666-715 | idem |

---

## 3. Grafo de relaciones y pipeline de ingestión

### 3.1 Vista de bloques
```
fuentes externas
  BrowserHistory ─┐
  LocalMailConnector ─┐
  LocalMessagesConnector ─┤
  LocalNotesConnector ─┤        Conversations (~/.claude/projects/*.jsonl)
  Transcription ───────┘                     │
        │                                    │
        └──────── CorpusRunner.runOnce ──────┘
                        │
              CorpusBuilder.Input (assemblyInput)
                        │
              CorpusBuilder.assemble  ── EpisodeBuilder.episodes
                        │                 (weigh / fold / resolve)
                        ▼
                     Corpus
                   ┌────┴─────┐
       CorpusRunner.write   CorpusFolder.saveBatch
        │            │              │
   passages+FTS   work_nodes    corpus/*.md (Markdown editable)
   (SemanticIndex) work_edges         │
        │                        Learned (correcciones del usuario)
   BrainSearch.embedEverything        │
                                      └──► realimenta assemblyInput
```

### 3.2 Paso a paso, con `archivo:línea`

1. **Arranque.** `CorpusRunner.start()` — `CorpusRunner.swift:100-110` lanza el loop; espera `warmUp = 90 s` (L74) y luego cada `interval = 30 min` (L70).
2. **Restauración de checkpoint.** `init` L80-96 lee el setting `corpus_checkpoint`, decodifica `IngestionCheckpoint`, y **lo conserva solo si `!saved.completed`** (L85-89). También restaura `corpus_run_history` (L91).
3. **Guarda de reentrada.** `runOnce` L130: si ya hay una pasada corriendo → `.busy`.
4. **Guarda de captura.** L131-135: `isCapturing` (L119-121) exige `graph_enabled == true` **y** `store.privacyState.isCapturing()`. Si no → `persistIngestionProgress(phase: .paused, ...)` (L133) y `.paused`.
5. **Política de energía.** L136-155: `BackgroundRunPolicy.decide` con estado térmico y `powerSource()` (IOKit, L297-314). Si difiere → `persistIngestionProgress(phase: .deferred, ...)` (L152) y `.deferred`.
6. **Ventana temporal.** L166-173: si hay checkpoint reanudable (`canResume(source:)`, IngestionCheckpoint.swift:33-35) se retoma su `windowStart`. `replayFloor = now - 7 días` (L172); `since = max(resumable?.windowStart ?? now - window, replayFloor)` (L173), con `window = 36 h` (L78). **Nunca se relee más de 7 días atrás**, aunque el checkpoint sea más viejo.
7. **Habilitación por fuente.** L180-194: flags por fuente + `sourceMayRun` (L347-352) que respeta el backoff exponencial guardado en `source_retry_after_<id>`.
8. **Recolección (fase `gathering`).** L198-213, en `Task.detached(priority: .utility)`: `BrowserHistory`, `conversations(since:limit:40)` (L578-600), `LocalMailConnector`, `LocalMessagesConnector`, `LocalNotesConnector`.
9. **Transcripción pendiente.** L215 → `transcribePending(since:)` L610-657. Carpeta opt-in `transcription_folder`; ledger `transcribed_files` (L619, recortado a 500 en L655); backoff de reintento L642-648; **procesa un solo archivo por pasada por el `break` de L652**.
10. **Correcciones del usuario.** L216 → `refreshCorrections(root:)` L730-734 → `CorpusFiles.learned(inFolderAt:)` (CorpusFiles.swift:375-389, lectura de disco fuera del MainActor).
11. **Construcción del Input (fase `assembling`).** L218-229 → `assemblyInput` L404-429: nodes ≤ 2000, clips ≤ 500, más nodos de mail/message/note; inyecta `forgotten: store.forgottenPeriods()` (L424) y `rejectedMerges()`/`markedByHand()` (L427).
12. **Ensamblado.** L233-235, `Task.detached` → `CorpusBuilder.assemble` (Corpus.swift:252-285):
    - gate de pausa primero: `guard input.privacy.isCapturing(at: input.now) else { return .paused }` (Corpus.swift:256);
    - señales → `EpisodeBuilder.episodes` → filtro de periodos olvidados (L259-260);
    - `weigh` (L262) puntúa cada episodio y aplica el gate `isSettled` (L476);
    - `fold` (L263) pliega entidades; `resolve` (L573-603) propone fusiones;
    - items (L265-274);
    - **segundo gate global de olvido** L280-282.
13. **Re-lectura del gate de pausa.** `CorpusRunner.swift:239-244`: tras el ensamblado se vuelve a comprobar la pausa antes de escribir. Si el usuario pausó durante el trabajo, no se escribe nada.
14. **Escritura (fase `writing`).** L251 → `write(_ corpus:)` L440-547:
    - `store.replacePassagesChecked` por item (L443) — error real propaga, no se traga;
    - `Task.yield()` cada 8 items (L446-452) para no bloquear el MainActor;
    - `corpus_last_passages` (L457);
    - nodos de entidad solo si `weight > 1 && !learned.hidden` (L470-479);
    - resolución subject→entidad vía `byForm`/`nodeID(for:)` (L494-506);
    - nodo de episodio + aristas `.cameFrom` (L508-518);
    - aristas `.workedWith` par a par (L521-526);
    - aristas `.partOf` de alias (L530-536);
    - preguntas de fusión al setting `corpus_merge_questions` (L541-542);
    - fire-and-forget `brain?.embedEverything(maximumBatches: 2)` (L544-546).
15. **Publicación a disco.** `CorpusFolder.saveBatch` (CorpusFiles.swift:694-731) escribe en un directorio de staging y publica atómicamente con `manifest.json` (`publish` L760-775).
16. **Cierre.** `recordSource` L265-273 (éxito/fallo + backoff), `corpus_last_problem`/`corpus_last_run` L276-277, `persistCheckpoint(..., completed: true)` L285.
17. **Destilado nocturno.** L290 → `distillIfDue` L666-715: setting `distilled_day` + `BackgroundRunPolicy.isOvernight`; arma un segundo `CorpusBuilder.Input` para el día anterior (L678-689), `Distillation.ready` (L691), `prompt`/`ask`/`parse` (L700-703), y guarda las afirmaciones como pasajes `.note` con la cita añadida (L706-713).

### 3.3 Checkpointing: cómo se reanuda tras una interrupción
- El checkpoint se escribe en cada cambio de fase: `persistCheckpoint(phase:completed:)` L379-390 → JSON de `IngestionCheckpoint` en el setting `corpus_checkpoint`.
- Al arrancar, `init` L85-89 lo rehidrata **solo si `!completed`**.
- `runOnce` L166-169 lo acepta solo si `canResume(source:)` (mismo `source` y no completado).
- **Lo que se reanuda es la ventana temporal, no el trabajo parcial.** El checkpoint guarda `windowStart` y `phase`, no qué items ya se escribieron. Reanudar significa volver a recolectar y reensamblar toda la ventana; la idempotencia la aporta el id determinista del episodio (Episodes.swift:153-155) y el corte por digest de `replacePassagesChecked`. Es correcto pero no barato: una interrupción en la fase `writing` con 2000 nodos rehace el 100% de la recolección y del ensamblado.
- El piso de 7 días (L172) impide que un checkpoint viejo dispare una relectura ilimitada.
- La UI expone que hay checkpoint: `BrainStatusView.swift:94` ("A previous capture will resume safely.").

---

## 4. Variables y estado

### 4.1 Estado en memoria de `CorpusRunner` (todo `@MainActor`, L49-64)
| Variable | Tipo | Rol |
|---|---|---|
| `store` | `Store` | acceso a SQLite |
| `brain` | `weak var BrainSearch?` | embeddings; weak para no retener |
| `ask` | closure | llamada al LLM para destilado |
| `loop` | `Task<Void, Never>?` | el temporizador; `stop()` L112-116 lo cancela |
| `phase` | `Phase` | fase observable |
| `isRunning` | `Bool` | **el único lock**: guarda de reentrada en L130 |
| `lastRun / lastWritten / lastProblem / lastDeferral` | — | último resultado |
| `runHistory` | `[CorpusRunRecord]` | 20 entradas (L316-325) |
| `checkpoint` | `IngestionCheckpoint?` | reanudación |
| `currentRunID / currentRunSource` | `String` | identidad de la pasada en curso |

### 4.2 Constantes de sintonía
`interval = 30 min` (L70), `warmUp = 90 s` (L74), `window = 36 h` (L78), `replayFloor = 7 días` (L172), backoff `min(24h, 30min·2^(n-1))` (L333), nodes ≤ 2000 y clips ≤ 500 (L404-429), conversaciones ≤ 40 (L578), `Task.yield()` cada 8 items (L446-452), historial de runs = 20, ledger `transcribed_files` = 500 (L655).
En `CorpusBuilder`: `entityLimit = 400` (Corpus.swift:249), mínimo 40 chars para mensajes (L371).
En `EpisodeBuilder`: `idleGap = 25 min`, `maximumLength = 4 h`, `minimumLength = 90 s`, `minimumSignals = 2` (Episodes.swift:96-107).
En `Distillation`: `minimumEpisodes = 2` (L44).
En `SemanticIndex`: `titleLimit = 160`, `sourceTextLimit = 1_000_000`.

### 4.3 Locks, colas y concurrencia
- **No hay mutex ni actor de ingestión.** El aislamiento es `@MainActor` en `CorpusRunner`, `Database`, `Store`, `Vault`, `CorpusFolder`; la exclusión mutua es el flag `isRunning` (L130). Funciona porque hay un único runner por proceso; **no protege de una segunda instancia de la app** ni de otro proceso abriendo la misma base.
- Trabajo pesado sale del MainActor con `Task.detached(priority: .utility)`: recolección (L198-213) y ensamblado (L233-235). `CorpusFiles.learned(inFolderAt:)` (CorpusFiles.swift:375-389) también lee disco fuera del actor.
- El único mecanismo de contención en SQLite es `busy_timeout = 3000` (Database.swift:70) + WAL.
- `Task.yield()` cada 8 items (L446-452) es lo que impide que la escritura congele la UI.
- Cooperación con el resto del sistema vía la fase `deferred` (política térmica/batería, L136-155) y el backoff por fuente (L327-352).

### 4.4 Estado persistido
Ver la tabla de §2.6. Todo es texto/JSON en `settings`. Punto importante: **`corpus_last_problem` se escribe desde tres sitios** (L276, L358-360 y la ruta de fallo cerca de L256), lo que dificulta razonar sobre qué error se está mostrando.

---

## 5. Funciones incompletas / stubs / TODOs

Grep sobre todo `Sources/` con `TODO|FIXME|fatalError|unimplemented|not implemented|no implementado`: **cero coincidencias**. La única coincidencia de `placeholder` es `PrivacyView.swift:53`, y es un placeholder de UI legítimo, no una marca de trabajo pendiente. **El subsistema no tiene stubs marcados ni `fatalError` alguno.**

Lo incompleto no está marcado como tal; hay que deducirlo del comportamiento:

| Comportamiento | Ubicación | Por qué cuenta como incompleto |
|---|---|---|
| Transcripción de un archivo por pasada | `CorpusRunner.swift:652` (`break`) | Con 30 archivos en cola, la carpeta tarda 15 h en vaciarse a `interval = 30 min`. Es un throttle, no un diseño de cola. |
| `corpus_merge_questions` se escribe y nadie lo lee | escrito en `CorpusRunner.swift:542`; grep en `Sources/BeLauncher/` → sin lectores | Feature a medio cablear: el motor propone fusiones y el usuario nunca las ve. |
| Reanudación de granularidad gruesa | `IngestionCheckpoint.swift:14-18` | El checkpoint guarda fase y ventana, nunca qué items quedaron ya escritos. Reanudar = rehacer todo. |
| `replacePassages` (sin `Checked`) traga errores | `SemanticIndex.swift:~466` (`try?`) | Sigue disponible para "escrituras puntuales de UI"; cualquier llamador nuevo que lo use hereda el bug que la variante `Checked` vino a arreglar. |
| Setting legado `corpus_rejected_merges` | `CorpusRunner.swift:744-747` | Se unen dos fuentes de verdad para el mismo dato. Migración a medias, sin fecha de retirada. |

---

## 6. Deuda técnica

### 6.1 ¿`Corpus`/`CorpusFiles` y `Vault`/`VaultDocument` son el mismo concepto renombrado?
**No, pero convergieron a la misma implementación por dos caminos distintos.** Son dos sistemas con propósitos diferentes que reinventaron la misma maquinaria:

| Eje | Corpus | Vault |
|---|---|---|
| Qué guarda | lo que la máquina infirió de tu actividad | lo que una persona escribió o aceptó |
| Unidad | `CorpusDocument` (episode/entity/statement) | `MemoryObject` (4 niveles, 8 kinds) |
| Nivel de verdad | derivado, regenerable | `committed` es la única verdad |
| Ciclo de vida | se reescribe en cada pasada | versionado con `supersedes`/`supersededBy` |
| Editable a mano | sí, y la edición gana (`CorpusFiles.write` L416-429) | sí, vía commits |
| En SQLite | `passages` + `work_nodes`/`work_edges` | `passages` con `source_kind = 'memory'` |

Conceptualmente distintos y la separación se justifica. **Lo que está duplicado es la infraestructura:**

1. **Staging + manifiesto, dos veces.** `CorpusFolder.StagedWrite`/`StagingManifest` (CorpusFiles.swift:616-623) + `publish` (L760-775) + `recoverStaging` (L777-795) es funcionalmente el mismo código que `Vault.StagedWrite`/`StagingManifest` (Vault.swift:12-20) + `writeFiles` (L309-333) + `publish` (L335-353) + `recoverStaging` (L355-372). Dos implementaciones de publicación atómica recuperable ante crash, que hay que mantener y testear en paralelo.
2. **Markdown + front matter YAML a mano, dos veces.** `CorpusFiles.render/parse` (L439-532) y `VaultDocument.render/parse` (L10-86). No hay un serializador común; el primero **importa los helpers escalares del segundo** (`quote`/`unquote`/`list`/`iso`/`date`), lo que crea una dependencia unidireccional rara: el modelo nuevo depende de los internos del viejo sin compartir el tipo.
3. **`Importers.slug`** (Importers.swift:121-130) es el generador de nombres de archivo de ambos sistemas (`CorpusFiles.filename` L568, `Vault.filename` L174). Una función de un importador de snippets de Alfred es el punto único de fallo de los nombres de archivo de toda la memoria.
4. **`CorpusFolder.defaultRoot()`** (L645) delega en `Vault.defaultRoot()`: el corpus vive dentro del árbol de la bóveda pero no comparte su tipo raíz. `CorpusFilesTests:144` ("El corpus no escribe en las carpetas que la bóveda lee como memoria") existe precisamente porque esa colisión es posible.

### 6.2 Complejidad algorítmica que crece con el tamaño de la memoria
| Sitio | Coste | Consecuencia |
|---|---|---|
| `Vault.path(forID:)` Vault.swift:126-135 | O(n) — escanea y parsea **todos** los archivos de objetos | `load(id:)` (L137) es O(n); `confirm(commitID:at:)` (L226-263) lo llama en bucle → **O(n²)** |
| `Vault.recordAIAudit` Vault.swift:56-64 | lee y reescribe `audit/ai.jsonl` entero **por cada evento** | O(n²) sobre el total de eventos de auditoría. Un `.jsonl` existe justamente para poder hacer append. |
| `CorpusBuilder.resolve` Corpus.swift:573-603 | par a par sobre entidades | acotado por `entityLimit = 400` (L249) → ~80k comparaciones por pasada |
| `write` aristas `.workedWith` CorpusRunner.swift:521-526 | par a par sobre subjects del episodio | acotado por el tamaño del episodio, pero sin tope explícito |

### 6.3 Otras
- **Sin `PRAGMA user_version`.** La migración es `CREATE TABLE IF NOT EXISTS` + `try? ALTER TABLE` que ignora el error (Store.swift:63-67). Funciona para añadir columnas; deja sin camino cualquier migración que necesite transformar datos, y no hay forma de saber en qué versión de esquema está una base.
- **Derivación de clave de TeamBrain: un solo SHA256.** `TeamBrain.key(fromPassphrase:team:)` L125-129 hace `SHA256.hash(passphrase + salt)`. Sin PBKDF2/scrypt/Argon2, una passphrase humana es fuerza-brutable a miles de millones de intentos por segundo en GPU. **Es la debilidad de seguridad más seria del subsistema.** El cifrado en sí (AES.GCM) es correcto; la llave es el eslabón.
- **`corpus_last_problem` escrito desde tres sitios** (L256, L276, L358-360).
- **Todo el estado de ingestión en un key-value de texto.** `IngestionProgress` e `IngestionCheckpoint` son `Codable` serializados a JSON dentro de `settings.value`. No consultable, no indexable, sin tipos en la base.
- **`Inbox.swift` y `Importers.swift` no pertenecen a este subsistema.** El primero es una proyección de UI usada solo por `GraphView`; el segundo es un importador de snippets que entró por la puerta de atrás vía `slug`.

---

## 7. Fallas y riesgos concretos

| # | Riesgo | Evidencia | Mitigación existente | Hueco |
|---|---|---|---|---|
| 1 | **Corte a mitad de escritura** | `write` L440-547 escribe pasajes, nodos y aristas sin una transacción que los abarque | cada `replacePassagesChecked` es atómica en sí (BEGIN IMMEDIATE/COMMIT) | Un crash entre el pasaje 40 y el 41 deja **el índice semántico y el grafo desincronizados**. El checkpoint (`phase: writing`) hace que se reejecute toda la pasada, y la idempotencia lo repara — pero entre el crash y la siguiente pasada (hasta 30 min) el grafo tiene episodios sin pasajes. |
| 2 | **Archivo que cambia mientras se procesa** | recolección L198-213 y `transcribePending` L610-657 | ledger `transcribed_files` por ruta (L619/655) | El ledger indexa por **ruta**, no por mtime ni por digest. Un archivo reemplazado con el mismo nombre **nunca se reprocesa**. Al revés: un archivo que se escribe mientras se lee entra parcialmente y su digest se guarda como definitivo. |
| 3 | **Edición manual concurrente con la pasada** | `CorpusFiles.write(_:over:)` L416-429 | la edición a mano gana; `saveBatch` publica atómicamente vía staging | El usuario que edita un `.md` **durante** la ventana entre `learned(inFolderAt:)` (L216) y `saveBatch` (paso 15) trabaja sobre una foto vieja. La regla "la mano gana" se aplica al contenido leído al empezar la pasada, no al del disco al publicar. |
| 4 | **Corrupción de la base** | `Database.init` L60-70 | WAL + `busy_timeout` + `wal_checkpoint(TRUNCATE)` al cerrar (main.swift:30,33) | Ninguna verificación de integridad al abrir (`PRAGMA integrity_check` no aparece en el repo). Ninguna copia de seguridad de la base. El índice semántico es reconstruible por diseño; `work_nodes`/`work_edges` y `settings` **no lo son**. |
| 5 | **Segunda instancia de la app** | el lock es el flag `isRunning` L130, en memoria | — | Dos procesos con la misma base **ejecutan dos pasadas simultáneas**. El WAL evita corromper el archivo; no evita escrituras entrelazadas ni que ambos machaquen `corpus_checkpoint`. **No verificado**: si hay un guard de instancia única en `main.swift`/`AppDelegate.swift` — está fuera de los 16 archivos asignados. |
| 6 | **Límites de tamaño** | `sourceTextLimit = 1_000_000`, `titleLimit = 160/240`, nodes ≤ 2000, clips ≤ 500, conversaciones ≤ 40, `entityLimit = 400` | truncado silencioso | El truncado **no se le reporta a nadie**: `String(text.prefix(sourceTextLimit))` (SemanticIndex.swift:480) descarta un millón de caracteres y devuelve éxito. Un documento de 3 MB se indexa al tercio sin aviso. Los topes de 2000/500/40 tampoco emiten señal: si tienes 5000 nodos en la ventana, 3000 **desaparecen en silencio** de esa pasada. |
| 7 | **Passphrase de TeamBrain fuerza-brutable** | `TeamBrain.swift:125-129` | AES.GCM correcto | Sin key stretching, un bundle robado se abre con una passphrase de diccionario. Ver §6.3. |
| 8 | **Realimentación del grafo** | mitigado en Corpus.swift:309 (salta ids `episode:`) y probado por `CorpusRunnerTests:218` | — | Cubierto. Se anota porque es el fallo obvio de este diseño y **sí está resuelto**. |
| 9 | **`recoverStaging` en dos sitios** | CorpusFiles.swift:777-795 y Vault.swift:355-372 | ambos corren en el init | Un bug de recuperación arreglado en uno no se arregla en el otro. `CorpusFilesTests:345` cubre el caso de crash en el corpus; **no verificado** que exista el test equivalente para `Vault`. |
| 10 | **Destilado depende de un LLM externo** | `distillIfDue` L666-715, closure `ask` | `Distillation.parse` L83-99 descarta toda línea sin cita `[n]` válida | Defensa correcta contra alucinación. Pero un fallo del proveedor solo deja `corpus_last_problem`; no hay reintento del destilado dentro del mismo día (`distilled_day` ya quedó marcado — **no verificado** si se marca antes o después del éxito). |

---

## 8. UX faltante

Lo que **sí** existe (mejor de lo que el brief asumía) — `Sources/BeLauncher/BrainStatusView.swift`:
- Barra de progreso de ingestión con fracción real, solo en fase `writing` (L52-62), con línea "N of M items · K passages".
- Última pasada: fuente, pasajes escritos y duración (L63-70).
- Aviso de checkpoint: "A previous capture will resume safely." (L94-97).
- Error de la última pasada, solo si `corpusPhase == "failed"` (L118-121), con `textSelection` habilitado.
- Aviso de Full Disk Access ausente con botón a Ajustes (L~110).
- `SourceCenterView.swift:46` muestra también `corpusLastProblem`.

Lo que falta:

| # | Hueco | Evidencia |
|---|---|---|
| 1 | **Las preguntas de fusión no se muestran nunca.** El motor propone fusionar entidades y lo escribe en `corpus_merge_questions` (CorpusRunner.swift:542); no hay un solo lector en `Sources/BeLauncher/`. El usuario solo puede rechazar fusiones editando el `.md` a mano (`CorpusFilesTests:266`). | grep sin lectores |
| 2 | **Sin errores por archivo.** `transcribePending` (L610-657) acumula reintentos por archivo en su ledger, pero la UI solo tiene un `corpusLastProblem` global. Un archivo que falla 5 veces es invisible. | BrainStatusView.swift:118 |
| 3 | **El truncado es silencioso.** Nada informa de que un documento se cortó a 1 MB, de que 3000 nodos quedaron fuera del tope de 2000, o de que solo se miraron 40 conversaciones. | §7 riesgo 6 |
| 4 | **El progreso solo se ve en `writing`.** `BrainStatusView.swift:53` exige `progress.phase == .writing`. Las fases `gathering` y `assembling` — que en una pasada grande son la mayoría del tiempo — no muestran barra; el usuario ve una app quieta. | BrainStatusView.swift:52-54 |
| 5 | **El error solo se ve si la fase es `failed`.** L118: `if let problem = ..., model.corpusPhase == "failed"`. Un problema registrado en una pasada que después se recupera **desaparece de la vista** sin que nadie lo haya leído. | BrainStatusView.swift:118 |
| 6 | **`deferred` no se explica.** La pasada se aplaza por calor o batería (L136-155) y se persiste la fase, pero no hay copy en `BrainStatusView` que diga "pospuesto porque el Mac está caliente". Desde fuera es indistinguible de estar roto. | grep sin copy de `deferred` |
| 7 | **Sin acción "ingerir ahora" visible junto al progreso.** `runOnce(ignoringPowerPolicy:)` existe (L128) pero **no verificado** que haya un botón que lo invoque desde `BrainStatusView`. | — |
| 8 | **El destilado nocturno es invisible.** `distillIfDue` (L666-715) escribe afirmaciones citadas y no hay indicador de que corrió, cuántas produjo, ni de que falló. | — |

---

## 9. Cobertura de test real

### 9.1 Inventario
| Archivo | Tests | Líneas |
|---|---|---|
| `Tests/BeLauncherCoreTests/CorpusTests.swift` | 31 | 481 |
| `Tests/BeLauncherCoreTests/CorpusFilesTests.swift` | 27 | 376 |
| `Tests/BeLauncherCoreTests/VaultTests.swift` | 40 | 593 |
| `Tests/BeLauncherCoreTests/EpisodeTests.swift` | 16 | 140 |
| `Tests/BeLauncherAppTests/GraphCorrectionsTests.swift` | 13 | — |
| `Tests/BeLauncherCoreTests/TeamBrainTests.swift` | 12 | 157 |
| `Tests/BeLauncherAppTests/CorpusRunnerTests.swift` | 11 | 237 |
| `Tests/BeLauncherCoreTests/DatabaseTests.swift` | 2 | 37 |
| `Tests/BeLauncherCoreTests/CorpusPerformanceTests.swift` | 1 | 39 |
| Relacionados: `RelevanceTests` 19, `PhrasesTests` 16, `ImportersTests` 8, `BackgroundRunPolicyTests`, `PrivacyTests`, `BrowserHistoryTests`, `TranscriptionTests` | — | — |

Los nombres de test están escritos como frases en español que describen la regla de negocio (algunos en inglés). Son legibles como especificación.

### 9.2 Qué está bien cubierto
- **Privacidad y pausa** — el eje mejor probado. `CorpusTests:39` (pausa no ensambla), `:54` (pausa por compartir pantalla), `:64` (pausa vencida deja volver), `:76` (app excluida), `:91` (dominio excluido), `:111` (secreto copiado no se convierte en señal ni en título), `:126` (la exclusión mira el destino del archivo, no solo la app). En el runner: `CorpusRunnerTests:46, 55, 74, 94`.
- **Olvido** — `CorpusRunnerTests:109` (lo olvidado no vuelve), `:131` (olvidar una tarde no borra la mañana), `:152` (sin nada olvidado entra igual), `GraphCorrectionsTests:158` (olvidar desde el grafo borra el origen).
- **Idempotencia de episodios** — `EpisodeTests:86` (mismo día dos veces = mismos ids), `:96` (dos recuerdos distintos no comparten id), `CorpusTests:449` (reensamblar no duplica).
- **Reglas de episodio** — los 16 tests de `EpisodeTests` cubren cada constante: idleGap (`:26`, `:34`), minimumSignals (`:43`), describesWork (`:48`, `:54`), minimumLength (`:62`), maximumLength (`:69`), orden (`:78`), subjects (`:104`), fallbackTitle (`:111`, `:120`), isSettled (`:127`), vacío (`:136`).
- **Correcciones a mano y crash-safety del corpus** — `CorpusFilesTests:57` (la mano nunca se pisa), `:75` (sobrevive a reescritura), `:102` (reescribir lo mismo no toca el archivo), `:108`/`:126` (rechazo de fusión persistente), `:136`/`:332` (archivo ajeno se ignora), `:160` (se encuentra por id aunque cambie el título), `:233` (no deja dos archivos peleando), **`:345` ("a crash between renamed corpus files does not make duplicate documents visible")** y `:363` (batch publica todo y queda legible). El staging del corpus **sí** tiene test de crash.
- **Realimentación del grafo** — `CorpusRunnerTests:218`, `GraphCorrectionsTests:189`.
- **Ventana temporal** — `CorpusRunnerTests:199`.
- **Exclusiones de fábrica** — `CorpusRunnerTests:169`, `:185`.
- **Rendimiento acotado** — `CorpusPerformanceTests:11` (10k memorias sintéticas medible y acotado); `GraphCorrectionsTests:19` (etiqueta heredada enorme no infla el grafo), `:326` (filtrar no congela), `:353` (escribir seguido dibuja una vez).
- **Citas del destilado** — `CorpusFilesTests:170` ("Una frase destilada lleva encima de dónde salió").

### 9.3 Huecos reales de cobertura
| # | Hueco | Por qué importa |
|---|---|---|
| 1 | **`DatabaseTests` tiene 2 tests, ambos sobre modo read-only** (`:8` "read-only diagnostics never create a missing database", `:19` "read-only access can inspect an existing database without switching its journal"). No hay test de bind de cada `SQLValue`, ni de propagación de `DatabaseError.sql`, ni del comportamiento bajo `busy_timeout`. |
| 2 | **Crash de staging de `Vault` sin test.** El del corpus existe (`CorpusFilesTests:345`); **no verificado** que exista el equivalente en `VaultTests` para `Vault.recoverStaging` (Vault.swift:355-372). Dos implementaciones, una probada. |
| 3 | **Reanudación desde checkpoint sin test end-to-end.** `IngestionCheckpoint` aparece en `ModelProviderRegistryTests` e `IngestionProgress` en `BackgroundRunPolicyTests:52` — **solo round-trip de Codable**. No hay test de "interrumpo en fase `writing`, reinicio, y la pasada retoma la misma ventana y no duplica". Es el mecanismo de recuperación central del subsistema. |
| 4 | **Ningún test de los topes.** Nada verifica qué pasa con >2000 nodos, >500 clips, >40 conversaciones o un texto >1 MB. Los límites de §7.6 son código no ejercitado. |
| 5 | **`transcribePending` sin test propio.** El `break` de un archivo por pasada (L652), el tope de 500 del ledger (L655) y el backoff de reintento (L642-648) no aparecen probados. `TranscriptionTests` existe pero cubre la transcripción, no la cola. |
| 6 | **Backoff por fuente sin test.** `recordSource`/`sourceMayRun` (L327-352): no hay test de que un fallo repetido efectivamente aplace la fuente ni de que el tope de 24 h se respete. |
| 7 | **Derivación de clave de TeamBrain sin test de fortaleza.** Los 12 tests de `TeamBrainTests` cubren seal/open/merge; ninguno afirma nada sobre el key stretching (no puede: no lo hay). |
| 8 | **`Vault.path(forID:)` O(n) sin test de rendimiento.** `CorpusPerformanceTests` cubre el índice con 10k memorias; nada cubre el `confirm()` O(n²) de Vault.swift:226-263. |
| 9 | **`distillIfDue` sin test de integración.** `Distillation.parse` sí está cubierto por `PhrasesTests`/`RelevanceTests`/`CorpusFilesTests:170`; la gate nocturna, `distilled_day` y el fallo del proveedor, no. |
| 10 | **`Inbox.swift` cubierto solo de refilón** por `UtilitiesTests`. Es un tipo de proyección trivial; el hueco es menor. |

---

## Resumen ejecutivo

**Lo sólido.** Las reglas de negocio del subsistema están escritas con criterio y probadas como especificación: la privacidad se comprueba tres veces por pasada (antes de recolectar, dentro del ensamblado, y otra vez antes de escribir), los ids de episodio son deterministas así que reensamblar nunca duplica, la edición manual de un `.md` siempre le gana a la máquina, el destilado descarta cualquier frase sin cita verificable, y las carpetas del corpus se publican con staging + manifiesto recuperable ante crash. 141+ tests sobre el subsistema, con nombres que se leen como requisitos. **Cero TODOs, cero `fatalError`.**

**Lo que duele.** Tres cosas, por orden:
1. **La derivación de clave de TeamBrain es un solo SHA256** (TeamBrain.swift:125-129). Un bundle compartido robado se abre por fuerza bruta. Es la única falla de seguridad real.
2. **La maquinaria está construida dos veces.** Staging+manifiesto y Markdown+YAML existen en dos implementaciones paralelas (`CorpusFolder` vs `Vault`), y solo una de las dos tiene test de crash. Los conceptos que separan Corpus de Vault son legítimos; la infraestructura duplicada no.
3. **Todo lo que se descarta, se descarta en silencio.** Truncado a 1 MB, tope de 2000 nodos, 500 clips, 40 conversaciones, un archivo de transcripción por pasada, y las preguntas de fusión que se escriben en un setting que nadie lee. El usuario nunca se entera de lo que no entró.

**Lo caro después.** `Vault.path(forID:)` es O(n) y hace que `confirm()` sea O(n²); `recordAIAudit` reescribe un `.jsonl` entero por evento. Ninguna de las dos duele hoy y las dos escalan mal por definición.

**La brecha de test más importante:** no existe una prueba end-to-end de reanudación tras interrupción. El checkpoint es el mecanismo de recuperación central del subsistema y solo está probado como round-trip de `Codable`.
