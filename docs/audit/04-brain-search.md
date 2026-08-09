# Auditoría 04 — Brain / Memory / Retrieval / Search

Base: worktree principal de `/Users/mac/Developer/beacon`, sobre `de18ca2` + cambios sin commitear.
Reglas: toda afirmación cita `archivo:línea`. Lo que no pude verificar está marcado **[no verificado]**.
Solo lectura: no se modificó ningún fuente.

**Respuesta corta a las dos preguntas del brief:**

1. **¿Hay semántica real?** Sí. Hay embeddings densos de verdad (Ollama / LM Studio / OpenAI), vectores normalizados persistidos en SQLite, similitud coseno, BM25 vía FTS5 y fusión RRF. Pero **degrada a búsqueda por palabras sin avisar en el resultado** cuando no hay motor de embeddings instalado (`BrainSearch.swift:119` usa `try?` y sigue con `[]`). El `gap` de `Retriever.swift:239-248` es el único canal que lo comunica.
2. **¿Hay presupuesto de tokens?** Sí, y es un límite real y testeado: `Retriever.defaultContextTokenBudget = 6_000` (`Retriever.swift:103`), aplicado en `Retriever.context(from:tokenBudget:)` (`Retriever.swift:108-152`). Pero **los cuatro llamadores de producción pasan `level: .b3`** (todo lo recuperado entra, acotado solo por los 6k): `AppDelegate.swift:1189`, `MCPTools.swift:179`, `:222`, `:567`. Los niveles b0/b1/b2 existen y solo se ejercitan en tests (`RetrievalTests.swift:238-239`).

---

## 1. Mapa de responsabilidades

### `Memory.swift` (154 líneas) — el objeto de memoria
- `MemoryObject` :8. `Level` :10-19 (`evidence`, `extracted`, `committed`, `outcome`) — **solo `committed` se trata como verdad**. `Kind` :21-30, `Status` :32-38. 18 propiedades almacenadas :40-58, `init` :60-94, `isCurrent(at:)` :98-103 (vigencia por `validFrom`/`validUntil` + `status`).
- `MemoryCommit` :111-138 con `State` (proposed/confirmed/discarded) — la cola de "por confirmar".
- `MemoryError` :140-154.
- Dependencias: ninguna del subsistema de búsqueda. Es la capa de datos pura.

### `BrainQuery.swift` (257 líneas) — intención en lenguaje natural
- `BrainQuery` :9. `Answer` :11. `Intent` :29-34: `whatDidWeDecide(topic:)`, `prepare(subject:)`, `remember(text:)`, `pulse`, `none`.
- `detect(_ query: String) -> Intent` :42-61 — corta el tema del texto **original** (no del plegado) para conservar acentos y mayúsculas; `guard trimmed.count >= 3` :45. Prefijos bilingües desde `Phrases`.
- `original(after:folded:raw:)` :65-77 — usa el prefijo más largo que coincide; el plegado es *length-preserving*, por eso el offset vale en el original.
- `whatDidWeDecide(...)` :80, `prepare(...)` :142, `relevant(_:in:kinds:)` :200-218 — este último es **fuzzy puro sobre memorias en RAM**, sin vectores.
- `shortDate` :224 / `shortDateTime` :228 usan `Loc.language.locale` (idioma de interfaz, no región del Mac).
- `CalendarEvent` :234 + `matches(_:)` :252 — sin EventKit, testeable.
- Dependencias: `Phrases`, `Fuzzy`, `MemoryObject`, `Loc`.

### `BrainSearch.swift` (132 líneas) — el orquestador
`@MainActor public final class BrainSearch`.
- `Progress` :13 (`passages`, `vectorised`, `engine`), `isComplete` :18, `percent` :19.
- `init(store:embedder:engine:)` :32.
- `detectEngine(hostedKeyAvailable:) async -> EmbeddingEngine?` :44.
- `progress()` :55, `index(memories:nodes:clips:notes:) -> Int` :62 → `store.reindex` :64.
- `embedPending(limit: Embedder.batchSize) async throws -> Int` :73, lanza `.noEngine` :74.
- `embedEverything(maximumBatches: 500)` :96, con `await Task.yield()` :102 entre lotes.
- `search(_:limit: 8) async -> Retriever.Result` :109 — detecta motor perezosamente :113, embebe la consulta :119 (`(try? …)?.first ?? []`), delega en `Retriever.retrieve` :121-130.
- Dependencias: `Store` (extensiones de `SemanticIndex`/`Indexer`), `Embedder`, `Retriever`.

### `Retriever.swift` (316 líneas) — ranking y presupuesto de contexto
- `BeBrainContextProvider` :22, `Selection` :23, `retrieve(result:level:tokenBudget:)` :40-58 — b0/b1 → `[]`, b2 → `prefix(4)`, b3 → todo; luego `Retriever.context`.
- `ContextSelection` :61. `Result` :73 (`hits`, `usedMeaning`, `usedWords`, `gap`).
- Constantes: `meaningFloor: Float = 0.42` :96, `expandFrom = 3` :100, `expansionScore = 0.001` :101, `defaultContextTokenBudget = 6_000` :103.
- `context(from:tokenBudget:)` :108-152 — empaqueta pasajes enteros; solo trunca el primero si él solo excede el presupuesto (:133-135).
- `estimatedTokens(for:)` :154-158, `boundedText(_:tokenBudget:)` :163-170, `normalised(_:)` :172.
- **`retrieve(query:queryVector:nearest:words:passage:related:passages:limit:)` :183-252** — el corazón. `guard trimmed.count >= 3` :194; pide `limit * 3` a ambos lados :200-203; `Semantic.fuse([meaningIDs, byWords])` :206; clasifica ruta :215-219; salto de grafo :227-237 (`break` en :234 = un pasaje por vecino); arma `gap` :239-248; devuelve `hits + expansions.prefix(limit / 2)` :250.
- `prompt(for:hits:tokenBudget:)` :274-300 — instrucción de sistema en inglés, citas numeradas `[n]`, aviso de truncado :278-280.
- `DateFormatter.retrievalStamp()` :310.

### `Semantic.swift` (213 líneas) — troceado, vectores, RRF
- `targetCharacters = 700` :22, `overlapCharacters = 140` :24, `minimumCharacters = 40` :27. `Passage` :29.
- `passages(of:target:overlap:)` :42-84 (solapa arrastrando cola :56-64; corte duro para frases sobredimensionadas :68-79).
- `sentences(of:)` :94-115 con `NLTokenizer(unit: .sentence)` y `setLanguage(Phrases.language(of:))` :102.
- `similarity(_:_:)` :124-129 — producto punto, **asume vectores unitarios**. `normalise(_:)` :133-139, `pool(_:)` :142-153.
- `encode(_:)` :159 / `decode(_:)` :164-177 — base64 de Float32 little-endian, byte a byte.
- `fusionConstant: Double = 60` :188, `fuse(_:weights:)` :190-201 (RRF).
- `digest(_:)` :210 — SHA256 hex, evita re-embeber lo que no cambió.

### `Embedder.swift` (231 líneas) — el motor
- `EmbeddingEngine` :22, `Shape` :24-29 (`.ollama`, `.openAI`), `isLocal` :40.
- `preferredLocalModels` :60-61 = `["bge-m3","multilingual-e5","e5-","mxbai-embed","snowflake-arctic-embed","nomic-embed","embed"]`; `rank(_:)` :63-69.
- `best(localModels:hostedKeyAvailable:)` :76-100 — endpoints **hardcodeados** :81-83 (`127.0.0.1:11434` Ollama, `127.0.0.1:1234` LM Studio); local siempre gana a hosted :94.
- `isEmbeddingModel(_:)` :103. `howToGetOne` :108-113 — **string en español hardcodeado, fuera de `L()`**.
- `EmbeddingError` :116-139 (`noEngine`, `missingKey`, `transport`, `emptyResponse`, `countMismatch`).
- `Embedder` :146 con `Transport` inyectable :147 y `keyLookup` :150. `batchSize = 16` :162.
- `embed(_:using:)` :164-210 — timeout 180 s :172, HTTP ≥400 → `.transport` :190-193, guard de `countMismatch` :206-208, `.map(Semantic.normalise)` :209.
- `parse(_:shape:)` :214-230 — en OpenAI ordena por `index` declarado, no por orden de llegada :227.

### `SemanticIndex.swift` (658 líneas) — persistencia SQLite del índice
- `IndexedSource` :9, `Kind` :10-22 (memory/node/clip/note/conversation), `label` :23, `key` :43 (`kind:id`), `key(_:)` parser :45.
- `IndexedPassage` :53-95; `titleLimit = 160` :78, `sourceTextLimit = 1_000_000` :81, `label(_:)` :84.
- `Retrieved` :110 con `Route` :111 (meaning/words/both/related) y `via` :127.
- `CorpusRepairReport` :139-145.
- `migrateSemanticIndex(repairOversizedTitles: Bool = true)` :166-225 — tabla `passages` :168, índices :185/:186/:189, FTS5 :194-199 (`tokenize="unicode61 remove_diacritics 2"` **[no verificado: línea exacta del tokenize]**), triggers ai/ad/au :202/:207/:213.
- `repairCorpusAmplification()` :234-~350 — dentro de `BEGIN IMMEDIATE` :263, tablas `_repaired` :270/:300/:321, `ROLLBACK` :338, reindex :344.
- `trimOversizedTitles()` :376. `fileSize` :399 (suma -wal/-shm), `contentSize` :409, `CompactionFailure` :419, `compact()` :448 (exige `contentSize*1.3 + 50 MB` libres, :450 **[no verificado: fórmula exacta]**).
- `replacePassages(...)` :470 — **se traga los errores** (variante no-checked). `replacePassagesChecked(...)` :478-517 con `BEGIN IMMEDIATE` :495 y `ROLLBACK` :514.
- `removePassages(for:)` :519, `storeVector(_:for:model:)` :523, `passagesNeedingVectors(model:limit:64)` :546-550, `passages(for:)` :564, `indexedPassageCount()` :571, `clearSemanticIndex()` :578.
- `storedVectors(limit: 50_000)` :599-602.
- **`nearest(to:limit:12)` :612-619** — carga TODOS los vectores almacenados y hace scan lineal en memoria.
- `matchingWords(_:limit:12)` :622-632 — `ORDER BY bm25(passages_fts, 1.0, 2.0)` :629.
- `passage(id:)` :634. `Semantic.ftsQuery(_:)` :648 — descarta tokens de 1 carácter, entrecomilla, une con OR, `*` de prefijo en el último.

### `Indexer.swift` (166 líneas) — de dónde sale el corpus
- `Item` :23-35. `minimumClipCharacters = 60` :39.
- `items(memories:)` :41-52 — statement primero, luego body, luego entities (:46-48).
- `items(nodes:)` :54-65 — `guard text.count >= 20` :61.
- `items(clips:)` :67-83 — `guard !SecretGuard.carriesSecret(text)` :78 (filtro de secretos **en indexación**, comentado :74-77).
- `items(notes:)` :85-90 + `dateFromFilename(_:)` :92-98 (parsea `yyyy-MM-dd HHmm` del nombre, cae a `.now` :97).
- `removals(indexed:current:)` :105-107.
- `Store.reindex(memories:nodes:clips:notes:)` :114-139 — `try? migrateSemanticIndex(repairOversizedTitles: false)` :120, bucle `replacePassages` :127-129, borra lo que desapareció :132-137.
- **`relatedSources(to:limit:4)` :146-165** — `.node` → `edges(from:)` :149; `.memory` → carga `nodes(limit: 200)` :155 y hace contención de substring plegado :156-159; `.clip/.note/.conversation` → `[]` :163 (callejón sin salida para la expansión).

### `SearchEngine.swift` (839 líneas) — el buscador del launcher (rama no-semántica)
- `ResultKind` :3-67, 18 casos; `label` :24-45 (algunos sin `L()`: `"App"` :26, `"Snippet"` :27), `symbol` :47-67.
- `SearchResult` :71-104. **`SearchInput` :106-166 — 19 propiedades almacenadas, struct-dios.**
- `resultLimit = 8` :169. `brainLaunchpadResults(limit:8)` :171-221 — escalera de puntajes hardcodeada 101_000 → 100_930 (:176-:217).
- **`search(_:in:calculation:files:limit:)` :223-~700** — una sola función monolítica: launchpad :235-243, QuickNote :266-272, comandos slash :286-292, WorkspaceLayouts :305-330, WorkQuery :390-398, intents de `BrainQuery` :418-440 (BELActionResolver :472-494, MissionPlanner :517 **[no verificado]**), calculadora :532, palabra clave de workflow :557, y luego las pasadas fuzzy: apps :575, atajos :590, memorias/pendingCommits :599 (bonus de commit `+200` **[no verificado: línea]**), clips :674-684 **[no verificado]**, orden final y promoción de alias :686-698 **[no verificado]**.
- `wantsBrainLaunchpad(_:)` :703. `answerResult(_:id:)` :725-731. `memorySubtitle(_:)` :735-741. `clipSubtitle(_:)` :743-754 — **español hardcodeado: `"Imagen"` :747, `"Enlace"` :749**.
- `matchShortcuts(_:needle:needleMask:keep:)` :760-830 — `parallelThreshold = 2_000` :785, camino secuencial :795, `nonisolated(unsafe)` + `DispatchQueue.concurrentPerform` :802-803, orden :790/:813.
- `preview(_:)` :832.

### `FuzzyMatch.swift` (136 líneas)
- `FuzzyMatch` :3-7. `Fuzzy.folded(_:) -> [Character]` :15-17.
- `match(query:candidate:)` :22-24 (pliega ambos lados, cómodo pero caro en bucles).
- `mask(_:) -> UInt32` :29-40 — huella de 27 bits de letras. `containsRun(needle:hay:)` :45-57 — O(n·m) naive.
- `cannotMatch(needleMask:candidateMask:)` :60-62 — prefiltro. `score(needle:hay:)` :67-93 — sin asignaciones. `match(needle:hay:)` :96-129 — con índices de resaltado. `isBoundary` :131-133.

### `Relevance.swift` (118 líneas) — qué merece indexarse
- `Signals` :18-38 (dwell, daysSeen, copiedFrom, neighbours, markedByHand).
- `bar = 0.30` :45, `meaningfulDwell = 60` :48, `saturatingDwell = 20*60` :51.
- `score(_:)` :53-81 — `markedByHand` corta a 1 :56; dwell :62-65; `daysSeen >= 2` → +0.35 y `>= 4` → +0.15 :70-71; `copiedFrom` +0.25 :74; vecinos tope 4 × 0.05 :78.
- `isWorthIndexing` :83-85, `explain(_:)` :91-105 (doble `joined` torpe :104), `signals(for:…)` :108-117.

### `RecallResults.swift` (69 líneas) — puente Brain → filas del launcher
- `rows(from:limit:5)` :15-32 — id `"recall-\(hit.passage.id)"`, título = extracto, **`score: 40 - position` :24** (queda por debajo de casi todo lo del launcher), `payload` = texto completo :29.
- `excerpt(_:limit:120)` :35-45, `subtitle(for:)` :52-59, `reason(_:)` :61-68.

### `KnowledgeSources.swift` (73 líneas)
- `KnowledgeSource` :7-28 con `State` :8-13. `KnowledgeSourceCatalog.current` :33-72 — 12 entradas.
- **Ninguna entrada está en `.connected`.** `files` :50-52 dice explícitamente "content is not automatically indexed yet"; `whatsapp` :62-64 y `mail-and-chats` :68-70 son `.planned`. Todo lo demás es `.available` o `.manual` (`audio` :47-49).

### `AppIndex.swift` (78 líneas)
- `Shortcut` :5-28 (pliega el título una vez en `init` :24-26 — decisión correcta), `Application` :30-44, `searchPaths` :54-63, `scan(paths:)` :65-77 — `FileManager.contentsOfDirectory` **síncrono**.

### `FileSearch.swift` (70 líneas)
- `FoundFile` :3-11, `FileSearch` :15 con `run` inyectable :17, `prefix = "f "` :24, `query(from:)` :26-31 (exige prefijo `f ` + ≥2 caracteres), `search(_:limit:6)` :33, `spotlight` :37-69 — lanza `/usr/bin/mdfind -onlyin $HOME -name`, lee hasta 64_000 bytes :56, `terminate()` :59.

### `LauncherModel.swift` (735 líneas) — la máquina de estado de la UI
`@MainActor @Observable`.
- `State` :10-16, `Key` :18-24, `Mode` :27-30.
- **`Action` :32-180 — 35 casos + `Codable` escrito a mano** (`ActionCodingKey` :83, `ActionKind` :88, `init(from:)` :97-137, `encode(to:)` :139-178).
- Estado observable :182-187. `AIState` :192-199, `aiWorking` :230, `aiAnswered` :231, `aiStreaming` :236-242, `aiFailed` :243, `clearAI` :244. Borrador de misión :203-228. Panel de acciones :246-291 — **`detail` :267-274 llama `try? dataSource()` en cada acceso**.
- `run(_:) -> Bool` :295-370. `query` didSet → `refresh()` :372-374. `isIndexing` didSet :376-378.
- **`brain: BrainSearch?` :382** — inyectado desde fuera, opcional.
- Estado de recall :389-391, `recallDelay = .milliseconds(220)` :395. `init` :407-427, `activate(mode:)` :432-446.
- **`refresh()` :452-491** — `guard !isIndexing` → `.loading` :453-457; consulta vacía → launchpad + recents :461-467; modo clipboard :468-470; si no, `FileSearch` :475 (**mdfind síncrono en el main actor**, comentado :472-474), `SearchEngine.search` :476-480, `mergeRecall` :482, `scheduleRecall` :483; `catch` → `.failed("\(error)")` :487.
- `mergeRecall(for:)` :499-504 — solo fusiona si `recallQuery == query`; promueve `.noMatch` → `.results` :503.
- **`scheduleRecall(for:)` :506-526** — `guard let brain, query.count >= 4, recallQuery != query` :507; cancela la tarea previa :508; espera 220 ms :510; `await brain.search(query, limit: 5)` :512; revalida identidad :514; guarda filas :516; `self.refresh()` :524.
- `handle(_:)` :532-580, `selected` :582, `runSelected()` :592-734 (switch gigante sobre todos los `ResultKind`).

### `ResultDetail.swift` (246 líneas)
- `ResultDetail` :5-33. `DetailBuilder.detail(for:snippets:flows:clips:memories:commits:expander:fileInfo:)` :37-222 — switch exhaustivo; caso `.recall` :155-159 muestra el pasaje completo.
- `looksLikeData` :224-230, `preview` :232-235.
- **`relative(_:now:)` :237-245 — español hardcodeado, sin `L()`: "hace instantes", "hace X min", "hace X h", "hace X d".**

---

## 2. Grafo de relaciones — el camino real de una búsqueda

### 2.1 Arranque (una sola vez)
```
main.swift:22   store.repairCorpusAmplification()
main.swift:32   store.compact()
main.swift:172  store.migrateSemanticIndex()
main.swift:173  BrainSearch(store:embedder:)
main.swift:177  brain.detectEngine()
main.swift:202  brain.embedEverything()
```
En paralelo, `AppDelegate.swift:523` vuelve a migrar (`repairOversizedTitles: false`), :524-526 construye `BrainSearch` y lo asigna a `model?.brain`, :531 `detectEngine()`, :533 `embedEverything(maximumBatches: 1)`, :558 `embedEverything(maximumBatches: force ? 4 : 2)`.

### 2.2 Indexación
```
BrainSearch.index()            BrainSearch.swift:62
 └─ Store.reindex()            Indexer.swift:115
     ├─ migrateSemanticIndex   Indexer.swift:120
     ├─ Indexer.items(...)     Indexer.swift:121-124
     ├─ replacePassages        Indexer.swift:128  → SemanticIndex.swift:470
     │   └─ Semantic.passages  Semantic.swift:42   (700/140/40 chars)
     └─ removePassages         Indexer.swift:136 → SemanticIndex.swift:519
```
Después, en segundo plano:
```
BrainSearch.embedEverything    BrainSearch.swift:96
 └─ embedPending               BrainSearch.swift:73
     ├─ passagesNeedingVectors SemanticIndex.swift:546  (lotes de 64)
     ├─ Embedder.embed         Embedder.swift:164       (lotes de 16, HTTP)
     │   └─ Semantic.normalise Semantic.swift:133
     └─ storeVector            SemanticIndex.swift:523  (base64 LE Float32)
```

### 2.3 Una pulsación de tecla
```
1. usuario teclea → LauncherModel.query didSet          LauncherModel.swift:372
2. refresh()                                            LauncherModel.swift:452
   a. isIndexing → .loading, corta                      LauncherModel.swift:453-457
   b. query vacía → launchpad + recents, .empty         LauncherModel.swift:461-467
   c. FileSearch.query → fileSearch.search (SÍNCRONO)   LauncherModel.swift:475 → FileSearch.swift:33
   d. SearchEngine.search(...)                          LauncherModel.swift:476 → SearchEngine.swift:223
      · brainLaunchpadResults                           SearchEngine.swift:171
      · BrainQuery.detect → intents                     BrainQuery.swift:42 / SearchEngine.swift:418-440
      · pasadas fuzzy (apps, atajos, memorias, clips)   SearchEngine.swift:575-684
      · matchShortcuts (paralelo si >2000)              SearchEngine.swift:760
   e. mergeRecall(for: query)                           LauncherModel.swift:482 → :499
   f. scheduleRecall(for: query)                        LauncherModel.swift:483 → :506
3. (220 ms después, si query.count >= 4)                LauncherModel.swift:507-510
   brain.search(query, limit: 5)                        BrainSearch.swift:109
   a. detectEngine si nil                               BrainSearch.swift:113
   b. Embedder.embed([query])  ← try?, cae a []         BrainSearch.swift:119
   c. Retriever.retrieve(...)                           BrainSearch.swift:121 → Retriever.swift:183
      · store.nearest(vector, limit*3)  SCAN LINEAL     SemanticIndex.swift:612
      · store.matchingWords(query, limit*3) BM25/FTS5   SemanticIndex.swift:622
      · Semantic.fuse (RRF, k=60)                       Semantic.swift:190
      · filtro meaningFloor 0.42                        Retriever.swift:96
      · salto de grafo desde top-3                      Retriever.swift:227-237 → Indexer.swift:146
      · gap textual                                     Retriever.swift:239-248
4. RecallResults.rows(from: result, limit: 5)           LauncherModel.swift:516 → RecallResults.swift:15
5. self.refresh() de nuevo                              LauncherModel.swift:524
6. mergeRecall inyecta las filas (score 40 - position)  LauncherModel.swift:499 / RecallResults.swift:24
7. selección → ResultDetail.detail(for:)                LauncherModel.swift:267 → ResultDetail.swift:37
```

### 2.4 Camino de contexto hacia el LLM (el único donde importa el presupuesto)
```
BeBrainContextProvider.retrieve(result:level:tokenBudget:)   Retriever.swift:40
 └─ Retriever.context(from:tokenBudget:)                     Retriever.swift:108
     └─ estimatedTokens / boundedText                        Retriever.swift:154 / :163
Consumidores:
 AppDelegate.swift:1189-1191  level .b3 → Retriever.prompt   Retriever.swift:274
 AppDelegate.swift:1194       remaining = max(400, 6000 - context.estimatedTokens)
 MCPTools.swift:179, :222, :567  level .b3, budget local :26
```

---

## 3. Variables y estado

| Estado | Dónde vive | Cuándo se invalida / reconstruye |
|---|---|---|
| Tabla `passages` (SQLite, disco) | `SemanticIndex.swift:168-186` | `replacePassages` borra+reinserta por fuente (:470); `reindex` borra fuentes desaparecidas (`Indexer.swift:135-137`); `clearSemanticIndex()` :578 la vacía entera |
| `passages_fts` (FTS5) | `SemanticIndex.swift:194-199` | Sincronizada por triggers ai/ad/au (:202/:207/:213). Se reconstruye a mano tras `repairCorpusAmplification` (:344 aprox) |
| Vectores (columna TEXT base64) | `storeVector` :523 | Se invalidan al **cambiar de modelo** (`model` va en la fila; test `RetrievalTests.swift:384`). Al editar el texto, los pasajes viejos se borran (test :394) |
| `BrainSearch.engine` | `BrainSearch.swift:32/44` | En memoria, por proceso. Se detecta perezosamente en la primera búsqueda (:113). **Nunca se re-detecta si Ollama arranca después** |
| Vectores cargados en RAM por consulta | `storedVectors(limit: 50_000)` :599 | **No hay caché**: se recargan enteros en cada llamada a `nearest` :612 |
| `AppIndex` (apps + atajos) | `AppIndex.swift:65` | Escaneo síncrono de disco; **[no verificado]** quién lo dispara y con qué frecuencia |
| `LauncherModel.rows` / `state` | `LauncherModel.swift:182-187` | Recalculado entero en cada `refresh()` :452 |
| `recallRows` / `recallQuery` / `recallTask` | `LauncherModel.swift:389-391` | `recallTask` se cancela en cada tecla :508; las filas solo se fusionan si la query no cambió :499-503 |
| `Fuzzy.folded` de atajos | `AppIndex.swift:24-26` | Calculado una vez en `init` (bien). En cambio los clips se re-pliegan en cada búsqueda (`SearchEngine.swift:674-684` **[no verificado]**) |

---

## 4. Funciones incompletas, stubs, TODOs

El grep de `TODO|FIXME|fatalError|not implemented` sobre los 17 archivos devuelve **un solo marcador real**:

- `LauncherModel.swift:472-474` — comentario `ponytail:` reconociendo que `mdfind` corre síncrono en el main actor.

Lo demás son huecos funcionales sin marcar:

- `Indexer.relatedSources` :162-163 — `.clip`, `.note`, `.conversation` devuelven `[]`. La expansión por grafo **solo funciona para memorias y nodos**; para clips y notas es un no-op silencioso.
- `KnowledgeSourceCatalog.current` :33-72 — ninguna fuente `.connected`; `whatsapp` :62 y `mail-and-chats` :68 son `.planned` (declarado honestamente, pero es capacidad ausente).
- `KnowledgeSources.swift:51` — búsqueda de archivos por nombre vía Spotlight; **el contenido de archivos no se indexa**.
- `IndexedSource.Kind.conversation` :10-22 existe como caso, pero `Indexer` **no tiene ningún `items(conversations:)`** (`Indexer.swift:41-90` solo cubre memories/nodes/clips/notes). Las conversaciones solo pueden entrar por otro camino **[no verificado: si `CorpusRunner` las inserta directamente]**.
- `Retriever` niveles b0/b1/b2 (:40-58) — implementados pero sin ningún llamador de producción.
- `Embedder.howToGetOne` :108-113 — texto de ayuda en español fuera de `L()`; parece placeholder.

---

## 5. Deuda técnica

**5.1 Dos sistemas de búsqueda paralelos, unidos con alambre.**
- Sistema A: síncrono, fuzzy, en RAM — `SearchEngine.search` :223 sobre apps, atajos, snippets, clips, memorias, bookmarks.
- Sistema B: asíncrono, SQLite + vectores — `BrainSearch.search` :109 → `Retriever.retrieve` :183.
- Se juntan solo en `LauncherModel.mergeRecall` :499-504, con como máximo 5 filas y `score: 40 - position` (`RecallResults.swift:24`), es decir **por debajo de cualquier match del launcher** (los puntajes de A van de 10_000 a 101_000, `SearchEngine.swift:176`/`:557`). El resultado semántico solo se ve si el sistema A no encontró casi nada.
- Además hay un tercer camino de "búsqueda": `BrainQuery.relevant` :200 hace fuzzy sobre memorias en RAM, ignorando por completo el índice semántico.

**5.2 `LauncherModel` hace demasiado.** 735 líneas: máquina de estado de UI, 35 casos de `Action` con `Codable` a mano (:83-178), estado de IA (:192-244), borrador de misión (:203-228), panel de acciones (:246-291), orquestación de búsqueda (:452-526) y ejecución de todos los tipos de resultado (:592-734). Cualquier tipo nuevo de resultado obliga a tocar `ResultKind`, `SearchEngine.search`, `DetailBuilder.detail` y `runSelected()`.

**5.3 `SearchEngine.search` :223-~700** es una función de ~480 líneas con más de 15 fuentes concatenadas y una escalera de puntajes mágicos hardcodeados (101_000, 100_990, 100_500, 100_120, 100_100, 10_000, +200). No hay una política de ranking; hay constantes dispersas.

**5.4 `SearchInput` :106-166 con 19 propiedades** — cada fuente nueva la engorda. Es acoplamiento por parámetro.

**5.5 Constante duplicada.** `MCPTools.swift:26` redefine `6_000` en vez de usar `Retriever.defaultContextTokenBudget` (`Retriever.swift:103`). Dos verdades para el mismo límite.

**5.6 Errores tragados.** `replacePassages` :470 usa `?? []` y descarta fallos de SQLite; existe `replacePassagesChecked` :478 pero `reindex` :128 llama a la versión que no chequea. Una indexación puede fallar entera y reportar 0 escritos sin distinguirlo de "no había nada".
Igual `Indexer.swift:120`: `try? migrateSemanticIndex(...)`.

**5.7 Strings en español fuera de `L()`** (el resto del subsistema sí usa `L()`):
- `ResultDetail.swift:237-245` — "hace instantes", "hace X min/h/d".
- `SearchEngine.swift:747` `"Imagen"`, `:749` `"Enlace"`; `memorySubtitle` :735-741 **[no verificado: el "sustituida" exacto]**.
- `Embedder.swift:108-113` — `howToGetOne`.
- Y al revés: `Retriever.prompt` :274-300 emite la instrucción de sistema **en inglés fijo** aunque el usuario opere en español.

**5.8 `detail` recomputado.** `LauncherModel.swift:267-274` llama `try? dataSource()` en cada lectura de la propiedad computada. En SwiftUI eso puede ser muchas veces por frame.

**5.9 Endpoints hardcodeados.** `Embedder.swift:81-83` fija `127.0.0.1:11434` y `127.0.0.1:1234`. Un Ollama en otro puerto o en la red local no es alcanzable sin recompilar.

---

## 6. Fallas y riesgos concretos

| Riesgo | Evidencia | Consecuencia |
|---|---|---|
| **Sin motor de embeddings, el producto es un buscador de palabras** y no lo dice en la fila del resultado | `BrainSearch.swift:112-120` (`try?` → `[]`), `Retriever.swift:239-248` (solo el `gap` lo comunica) | El usuario cree que "Be Brain" entiende; en realidad hace BM25 |
| **Motor detectado una sola vez por proceso** | `BrainSearch.swift:113` solo detecta si `engine == nil`; no hay reintento ni invalidación | Si Ollama arranca después del launcher, la sesión entera queda sin semántica hasta reiniciar |
| **Fuente gigante** | `IndexedPassage.sourceTextLimit = 1_000_000` :81; test `RetrievalTests.swift:342` | Está acotado. Pero 1 MB / 700 chars ≈ 1.400 pasajes de una sola fuente, cada uno pidiendo un vector |
| **Miles de resultados** | `store.nearest` :612 carga hasta 50_000 vectores (:599) y ordena en cada consulta | Latencia que crece linealmente con el corpus, en cada tecleo pasado el debounce |
| **Consulta vacía o de 1-2 caracteres** | Cubierto: `Retriever.swift:194` (`>= 3`), `BrainQuery.swift:45` (`>= 3`), `LauncherModel.swift:507` (`>= 4`), `Semantic.ftsQuery` :648 descarta tokens de 1 char | Sin riesgo aparente |
| **Índice corrupto / inflado** | `repairCorpusAmplification()` :234 con transacción y `ROLLBACK` :338; `compact()` :448 con guarda de espacio libre :450 | Mitigado. Corre en `main.swift:22`/`:32`, es decir **solo al arrancar** |
| **Errores de SQLite invisibles** | `replacePassages` :470 (`?? []`), `Indexer.swift:120` (`try?`) | Un índice a medio construir se ve idéntico a uno vacío |
| **Secretos** | `Indexer.swift:78` filtra en indexación con `SecretGuard.carriesSecret`; el comentario :74-77 admite que el filtro débil dejó pasar cosas antes | El filtro correcto está puesto, pero **los clips ya indexados antes del endurecimiento siguen en disco** salvo reindexación |
| **`FileSearch` spawnea un proceso por consulta** | `FileSearch.swift:37-69`, `mdfind` con `terminate()` :59 | Con tecleo rápido, procesos `mdfind` encadenados; el corte a 64_000 bytes :56 acota la salida pero no el spawn |
| **Fecha inventada en notas** | `Indexer.swift:97` — si el nombre de archivo no parsea, `occurredAt = .now` | Notas viejas se ordenan como recientes |
| **Notas cuyo cuerpo no se indexa entero** | `Indexer.swift:88` usa `note.excerpt`, no el texto completo | Una nota larga solo es buscable por su extracto |

---

## 7. Rendimiento

**Cuellos reales:**

1. **`Store.nearest` :612-619 — O(n) sobre todos los vectores, en cada consulta.** Carga desde SQLite (`storedVectors` :599, hasta 50_000 filas), decodifica base64 → `[Float]` (`Semantic.decode` :164, byte a byte), calcula producto punto y ordena. Sin caché, sin índice ANN, sin lote. Es el techo del subsistema.
2. **`Indexer.relatedSources` :155 — `nodes(limit: 200)` por cada hit de tipo memoria.** `Retriever` expande desde los 3 primeros hits (`expandFrom = 3` :100), o sea hasta 3 cargas de 200 nodos + contención de substring plegado (:156-159) por búsqueda.
3. **`mdfind` síncrono en el main actor** — `LauncherModel.swift:475`, reconocido en el comentario :472-474. Bloquea la UI durante el spawn + lectura.
4. **`Fuzzy.match(query:candidate:)` :22-24 pliega ambos lados en cada llamada.** En el bucle de clips (`SearchEngine.swift:674-684` **[no verificado]**) eso es un `folded()` de la aguja por cada clip. `AppIndex` sí lo resuelve bien pre-plegando en `init` (:24-26), y `matchShortcuts` :780 usa la vía sin asignaciones (`Fuzzy.score` :67).
5. **`Fuzzy.containsRun` :45-57 es O(n·m) naive**, mitigado por el prefiltro de máscara de 27 bits (:29-40, :60-62) que el test `SearchPerformanceTests.swift:25` verifica que nunca descarta un match real.
6. **Paralelismo puntual y correcto**: `matchShortcuts` usa `DispatchQueue.concurrentPerform` solo por encima de 2.000 atajos (:785-803). Test de presupuesto de frame con 15k bookmarks en `SearchPerformanceTests.swift:46`.
7. **`refresh()` corre dos veces por recall** — `scheduleRecall` :524 llama `self.refresh()`, que a su vez rehace `FileSearch` (:475) y `SearchEngine.search` (:476) completos aunque lo único nuevo sean 5 filas de recall. Trabajo duplicado por cada consulta con brain.

**Lo que sí está acotado:** `limit: 8` por defecto (`SearchEngine.swift:169`, `BrainSearch.swift:109`), `limit * 3` en ambas ramas del retriever (`Retriever.swift:200-203`), `prefix(limit / 2)` en expansiones (:250), lotes de 16 al embeber (`Embedder.swift:162`) y de 64 al leer pendientes (`SemanticIndex.swift:546`), `Task.yield()` entre lotes (`BrainSearch.swift:102`), debounce de 220 ms (`LauncherModel.swift:395`) y cancelación de la tarea previa (:508).

**Lo que falta:** paginación (no existe en ninguna capa; todo es top-N fijo) y cualquier forma de índice vectorial aproximado.

---

## 8. UX faltante

1. **No hay estado "buscando…" para el recall.** `LauncherModel.State` :10-16 tiene `.loading`, pero `refresh()` solo lo usa para `isIndexing` (:453-457). Los 220 ms de debounce + la latencia HTTP del embedding + el scan de vectores transcurren sin ninguna señal visible.
2. **La degradación a "solo palabras" no llega a la fila.** `Retriever.Result` trae `usedMeaning` / `usedWords` / `gap` (:73) y `RecallResults.reason(_:)` :61-68 sabe decir "by meaning" / "by words", pero el `gap` de :239-248 no tiene un consumidor evidente en el launcher **[no verificado: si alguna vista lo muestra]**.
3. **Sin feedback de construcción del índice en el launcher.** `BrainSearch.Progress` :13-19 expone `passages`, `vectorised` y `percent`, y lo consume Ajustes (`SettingsModel.swift:1424-1427`), pero el launcher solo tiene el binario `isIndexing` (:376).
4. **Sin instrucción de "instala un modelo".** `Embedder.howToGetOne` :108-113 existe, pero es un string en español fuera de `L()` y **[no verificado]** si alguna vista lo muestra cuando `detectEngine()` devuelve `nil`.
5. **Los errores se muestran crudos.** `LauncherModel.swift:487` → `.failed("\(error)")`: al usuario le llega la descripción de debug de un error de Swift.
6. **"Sin resultados" existe** (`.noMatch`, promovido a `.results` en :503 si llega recall), pero el usuario ve primero "sin resultados" y 220 ms después aparecen filas: parpadeo.
7. **Fechas y subtítulos en español fijo** (`ResultDetail.swift:237-245`, `SearchEngine.swift:747`/`:749`) en una app que por lo demás está localizada.
8. **El catálogo de fuentes no muestra ninguna conectada** (`KnowledgeSources.swift:33-72`) — honesto, pero para el usuario de `SourceCenterView.swift:70` la pantalla dice que nada está enchufado.

---

## 9. Cobertura de test real

### Bien cubierto

**`RetrievalTests.swift` (530 líneas)** — el archivo más denso del subsistema:
- Elección de motor (:5-41): prefiere el modelo mejor rankeado no el primero (:8), no confunde modelos de chat (:17), local gana a hosted (:23), sin nada no inventa motor (:37).
- Parseo de respuestas (:43-108): formato Ollama (:46), OpenAI respetando `index` (:54), rechazo por `countMismatch` (:61), vectores ya normalizados (:75), motor cloud sin clave falla antes de enviar (:94).
- Retriever (:110-260): doble acierto marcado y priorizado (:119), `meaningFloor` rechaza parecidos flojos (:132), **sin vectores sigue por palabras y lo dice** (:145), el grafo trae lo relacionado (:159), no duplica lo ya encontrado (:178), consulta de 2 letras no dispara nada (:192), el prompt numera fuentes y prohíbe inventar (:204), **`context` respeta el presupuesto conservando la cita (:216)**, niveles b0/b2 explícitos (:229).
- Índice (:342-529): fuente absurda acotada antes de trocear (:342), reparación quita amplificación y conserva evidencia (:352), **cambio de modelo invalida vectores (:384)**, editar texto borra pasajes viejos (:394), borrar fuente la saca del FTS (:406), round-trip de vectores (:417), **la pasada de vectores no recorre la tabla entera por lote (:430)**, títulos gigantes recortados (:458/:481/:490), base sana no se declara hinchada (:520).

**`SemanticTests.swift` (162)** — troceado (:8-50): texto corto = 1 pasaje, fragmento corto no se indexa, orden preservado, solapamiento, frase única sobredimensionada, abreviaturas no parten frases (:45). Vectores (:52-78): normalización, vector de ceros sin NaN (:62), coseno consigo mismo = 1 y con el opuesto = -1 (:68). Digest (:154-160).

**`RelevanceTests.swift` (164)** — 10 casos (:8-79) que cubren cada señal, la saturación en 1.0 (:39) y ambas direcciones de `explain` (:54/:61).

**`BrainQueryTests.swift` (251)** — detección bilingüe y negativa (:24), decisión vigente vs. todo lo dicho (:41), interpretación nunca pasa por decisión (:56), decisión vencida sin reemplazo (:65), preparación con calendario (:87/:173), admite no saber (:110/:117), y en el launcher: la pregunta gana a todo (:149), cuenta las fuentes (:160), `recordar…` propone captura (:187), **una búsqueda normal nunca es secuestrada por brain (:242)**.

**`SearchPerformanceTests.swift` (136)** — `Fuzzy.score` concuerda siempre con `Fuzzy.match` (:10), **la máscara de letras nunca descarta un match real (:25)**, y una pulsación sobre 15k bookmarks entra en presupuesto de frame (:46).

**`BELSearchIntegrationTests.swift` (58)** — 5 casos de resolución de acciones nativas en resultados ejecutables (:6-52).

Otros que tocan el subsistema: `MCPToolsTests.swift` (:16 migración, :53-57 brain con embedder falso, :63-64 brain plano), `MCPHealthTests.swift` (:65/:120/:146/:181/:450), `CorpusPerformanceTests.swift:27` (`store.reindex`), `PrivacyTests.swift` (:78, :239), `VaultTests.swift:333` (`struct BrainSearchTests`), `PhrasesTests.swift:143`, `CorpusFilesTests.swift:298-301`.

### Huecos de cobertura

| Sin test aparente | Por qué importa |
|---|---|
| `SearchEngine.search` :223 como función completa | ~480 líneas, 15+ fuentes, escalera de puntajes mágicos. Solo se testea de refilón vía `BrainInLauncherTests` (:135-251) y BEL (:6-52) |
| `LauncherModel.scheduleRecall` :506-526 | Debounce, cancelación, revalidación de identidad de consulta y el `refresh()` reentrante. Toda la lógica de carrera del recall está sin cubrir |
| `LauncherModel.mergeRecall` :499-504 | La única costura entre los dos sistemas de búsqueda |
| `RecallResults.rows` / `excerpt` / `reason` | `RecallResults.swift:15-68` — no aparece en ningún test **[no verificado: no encontré referencias en `Tests/`]** |
| `Indexer.relatedSources` para `.clip`/`.note` | El camino que devuelve `[]` (:163) nunca se ejercita |
| `Indexer.dateFromFilename` :92-98 | El fallback a `.now` (:97) no está cubierto |
| `FileSearch.spotlight` :37-69 | `run` es inyectable (:17), así que es testeable, pero no encontré el test **[no verificado]** |
| `Store.nearest` con corpus grande | `RetrievalTests.swift:430` cubre los lotes de embedding, no la latencia del scan de similitud |
| `ResultDetail.relative` :237-245 | Formateo de fechas sin cubrir |
| `Embedder` con timeout / red caída | Se testea HTTP ≥400 y `countMismatch`, no el timeout de 180 s (:172) |

---

## Resumen ejecutivo (3 líneas)

La semántica es real y está bien construida (RRF sobre coseno + BM25, vectores normalizados, presupuesto de tokens de 6k respetado y testeado), pero **el retrieval vectorial es un scan lineal completo por consulta** (`SemanticIndex.swift:612`) y **degrada a búsqueda por palabras sin decírselo al usuario** cuando no hay modelo local.

La deuda estructural está en la costura: **dos buscadores independientes** unidos por 5 filas con puntaje 40 (`RecallResults.swift:24`), un `SearchEngine.search` de ~480 líneas y un `LauncherModel` de 735 que hace de máquina de estado, ejecutor y orquestador a la vez.

El agujero más barato de tapar es de UX: no hay "buscando…", el `gap` que explica por qué la respuesta es floja se calcula (`Retriever.swift:239-248`) y aparentemente no se muestra, y los errores llegan crudos con `"\(error)"` (`LauncherModel.swift:487`).
