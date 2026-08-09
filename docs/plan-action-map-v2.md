# Plan de implementación — BeLauncher Spotlight/AI Action Map v2

Origen: `~/Desktop/BeLauncher_Spotlight_AI_Action_Map_v2.md` (1027 líneas, 18 secciones, 5 fases).
Base auditada: `de18ca2`. Auditoría hecha por dos agentes Codex en paralelo vía Orca (`run_c36318373f50`).
Informes crudos: `AUDIT-native.md` y `AUDIT-ai.md` en el scratchpad de la sesión.

## Reconciliación T-02

Estado reconciliado contra `main` en `36e7aea` (`v0.32.52`), la historia posterior y
`.foreman/tracker-reconciliation.md`. Reminders, Contacts y Photos ya no son `unavailable` en
el catálogo: las rutas de lectura/búsqueda y las capacidades implementadas tienen handlers y
pruebas enfocadas. Esto no prueba el comportamiento en el MacBook: permisos TCC, Automation,
Full Disk Access, la apertura exacta y el share picker siguen requiriendo validación de runtime.
`contacts.share` prepara un vCard y tiene una ruta de picker, pero permanece parcial hasta observar
un servicio de compartir real.

Este documento es un plan. No se escribió código de producción.

---

## 1. Veredicto sobre el spec

El spec es una buena arquitectura con tres afirmaciones que no sobreviven al contacto con el repo. Hay que corregirlas antes de implementar, no durante.

**a) Los números 156 y 120 no son entregables, son un catálogo de intenciones.**
Los números del spec son objetivos de catálogo, no una medición del runtime actual. En esta base, `SystemCommand.Kind` tiene 22 casos y el catálogo contiene 58 entradas nativas con disponibilidad `implemented`; esas cifras describen el estado auditado de este checkout y pueden cambiar con el código. Otras acciones siguen siendo rutas conceptuales `shortcuts` o `unavailable`: ni el conteo del spec ni la existencia de una definición convierten una acción en invocable. El criterio de aceptación debe separar definiciones de acciones realmente invocables por ID estable desde tests.

**b) `ActionRegistry` ya existe en el repo y significa otra cosa.**
`Sources/BeLauncherCore/ResultAction.swift:130` ya define `ActionRegistry.actions`, y `ResultAction` ya es el modelo de acciones de la UI, con riesgo destructivo incluido. Además hay tres catálogos más: `SystemCommand.Kind` (22 comandos en este checkout, `SystemCommand.swift:57`), `FlowStep` (`Flow.swift:25`) y `LauncherModel.Action` (`LauncherModel.swift:139`). Introducir el contrato del spec en paralelo da colisión de nombre y dos fuentes de verdad para ID, riesgo y confirmación.

**c) La sección 6.4 (fork de LiteRT-LM) no es un prerrequisito del valor que promete.**
Verificado upstream: LiteRT-LM declara CPU/GPU en macOS, CLI con Gemma 4 E4B y `--enable-speculative-decoding`, y Gemma publica drafters MTP. La **API Swift está en early preview**, no estable. El repo ya contiene piezas de spike aisladas para MTP y prefix/KV cache (`BELMTPScheduler` y `BELPrefixKVCache`) con tests; eso no equivale a una integración de producción con LiteRT-LM ni a un backend Metal. `beMetalFused`, el contrato Swift de producción y la integración completa de fork/bridge/artefacto E4B siguen siendo trabajo propio. La integración de producción queda diferida a X1-X5 y no bloquea el criterio funcional "local por defecto en Apple silicon", que se cumple hoy con Ollama/LM Studio más Apple Foundation Models.

---

## 2. Decisiones de arquitectura

1. **Adaptar, no duplicar.** El contrato nuevo se llama `BELActionDefinition` con IDs `native.*` / `ai.*`, y `ResultAction` pasa a ser una **proyección de vista** del contrato, no un modelo paralelo. `SystemCommand.Kind` y `FlowStep` se migran a definiciones + handlers progresivamente. Costo M. La alternativa (dos contratos con tabla bidireccional) es L y deja deuda permanente.
2. **`titleKey` estable, nunca el texto.** Hoy la etiqueta inglesa es la clave de lookup (`Localization.swift:64`). Cambiar una etiqueta rompe la resolución. El registry necesita clave estable con la localización en la capa de UI.
3. **Las acciones `S` son fallback documentado, no API de Spotlight.** No existe API pública para enumerar o invocar acciones arbitrarias de Spotlight, y el spec correctamente prohíbe hurgar en sus índices. Spotlight es superficie de **exposición** (App Intents), no backend. El repo ya tiene `Sources/BeLauncher/AppIntents.swift`, 16 intents curados y `BeLauncherShortcuts: AppShortcutsProvider`, además de un catálogo/deep link y tests de puente; N6 conserva la integración de producción y la validación de discoverability/runtime como trabajo pendiente. Cada acción `S` necesita: Shortcut `BEL • Categoría • Acción` creado y validado, mapping persistido por ID, args tipados, captura de stdout/exit code, y estado `unavailable` honesto cuando falta.
4. **`bebrain.local.core` se fija como ID estable ya, con backend intercambiable.** Se declara healthy solo cuando algún backend local pasa el health check. LiteRT-LM entra después detrás del mismo ID, sin tocar definiciones de acciones.
5. **El gate de nube va justo antes de construir el request, no en el caller.** Hoy `IntelligenceClient.build` (`Intelligence.swift:340`) serializa el prompt tal cual, y `Sensitivity` solo protege lo que el caller marcó `.confidential`. Eso no cumple la sección 7.

---

## 3. Plan ordenado

El paso 0 es el cuello de botella real: casi todo lo de AI depende del contrato. Es tarea de un solo dueño, no paralelizable.

### Paso 0 — Contrato único (M) · BLOQUEANTE

`BELActionDefinition` + `Capability` + `RiskLevel` (R0-R3) + input/output schema + `brainContextLevel` + `routePolicy` + `freshness`. Los 156 + 120 IDs como datos semilla, cada uno con estado explícito: `implemented` / `shortcut-fallback` / `unavailable`. `ResultAction` como proyección.
Los rótulos editoriales `implemented`, `partial`, `pending` y `deferred` se usan en este documento para describir evidencia y trabajo restante; no son todos estados del enum de `BELActionDefinition`. El enum de disponibilidad del runtime solo contiene `implemented`, `shortcutFallback` y `unavailable`.
Verifica: IDs únicos, encode/decode, cada acción `implemented` invocable por ID desde test, aliases bilingües resuelven, ninguna acción sin estado.

### Vía nativa (después del paso 0)

| # | Paso | Tamaño | Verifica |
|---|---|---|---|
| N1 | Handler protocol con el orden de resolución 4.1 (API pública → AppIntent propio → Shortcut → URL/NSWorkspace → AppleScript first-party → shell allowlisted) + capability gate central y errores tipados | M | Cada fallback se elige en el orden correcto; matriz denied/partial/granted; confirmación R2/R3 |
| N2 | Envolver lo que ya funciona: open/reveal/trash, system commands, clipboard, calculadora, unidades, timer/wait, URL allowlist, flows | S/M | Tests actuales siguen verdes + receipts y exit errors |
| N3 | Primer lote público real: FileManager, PDFKit, NSOpenPanel, ScreenCapture, EventKit. Reminders/Contacts/Photos tienen ya acciones implementadas para lectura, búsqueda y operaciones seleccionadas; falta validar API/entitlements y comportamiento de permisos en runtime | L | Tests por acción + matriz de permisos + evidencia MacBook separada |
| N4 | Capa Shortcuts estable: crear/validar `BEL • …`, mapping por ID, availability, stdout/exit code, requisito de foreground | L | Sin Shortcuts instalado; nombre ausente; CLI no-cero; caracteres de control |
| N5 | Parser nativo: exacto → prefijo → fuzzy → clasificador, salida `{actionID, confidence, args}` | M | Inglés y español, ambiguos, desconocidos, IDs estables |
| N6 | Completar la integración de producción de App Intents: 16 acciones curadas, split background/foreground, deep link y vínculo verificable con el runtime | L | Compila el target, discoverability en Spotlight/Shortcuts, unavailable en runtime |
| N7 | Hardening de release: bundle firmado, gate explícito de sandbox, automation entitlement, usage keys en Info.plist | M | macOS estable + beta no bloqueante, Intel y Apple silicon, offline, permisos denegados; sandbox queda bloqueado por arquitectura |

### Vía AI (después del paso 0)

| # | Paso | Tamaño | Verifica |
|---|---|---|---|
| A1 | `BELLanguageModelProvider` + `ModelRequest/Response` + adapters LocalHTTP / OpenAI / Anthropic / Google + Apple FM con chequeo de disponibilidad en runtime | M | Fakes de generate, cancelación, contextWindow, capabilities, cero red en tests |
| A2 | `MacCapabilityDetector`: arquitectura, memoria unificada, presión de memoria, thermal, low power, batería, red, Foundation Models | M | Matriz simulada 8/16/32/64 GB, thermal, FM ausente/presente |
| A3 | Reemplazar `ModelRouter` (`Intelligence.swift:148`) por el scoring de 6.3 + cache de health + fallback + política de freshness | M | Tabla de scores determinista; `local-only` nunca elige nube; ruta stale rechazada |
| A4 | B0-B3 con `BeBrainContextProvider.retrieve(tokenBudget:)`: convertir el límite de hits actual (`MCPTools.swift:206`, que cuenta hits, no tokens) a presupuesto real de tokens, preservando citas y gaps | M | Corpus vacío/ligero/rico; presupuesto nunca excedido; distinto resultado por nivel |
| A5 | Frontera de nube: scopes de memoria, flag `localOnly`, redacción inmediatamente antes de construir el request, auditoría de clase de proveedor sin payload | M | Fixtures de secretos, local-only, confidencial, request inspeccionado |
| A6 | Validador de salida estructurada: JSON Schema, campos desconocidos, reparación acotada, validación de tool-call | M | JSON válido, truncado, schema mismatch, prompt injection, fallback de error |
| A7 | Default local barato: LocalHTTP + Apple FM auxiliar, `bebrain.local.core` con health provisional y descubrimiento real de modelos | M | Apple silicon con Ollama/LM Studio; offline; sin nube conectada; fallback explícito |
| A8 | Fase 3: writeback `save` / `forget` / actualización de proyecto con confirmación y audit log | M | Propuesta/confirmar/descartar; forget borra índice y vectores; cero escritura silenciosa |

### Diferido a spikes independientes (no bloquean nada)

| # | Paso | Tamaño | Nota |
|---|---|---|---|
| X1 | Spike de LiteRT-LM **sin fork**: compilar y correr el CLI / la Swift preview, medir, registrar incompatibilidades y comparar con las piezas MTP/KV ya testeadas | M | Puerta de entrada a todo lo demás. Si esto no pasa, X2-X5 no existen |
| X2 | Fork disciplinado + artefacto E4B + validación target/drafter + bridge C++ | L | Solo después de X1 |
| X3 | Prefix/KV cache versionado con aislamiento por scope de privacidad | L | Riesgo de fuga entre usuarios/acciones. Requiere telemetría antes |
| X4 | Scheduler MTP adaptativo + telemetría local | M/L | Decodificación ordinaria primero |
| X5 | Backend Metal de attention fusionada, tras feature flag | L | Solo se mergea si el benchmark gana sin divergencia numérica |

---

## 4. Riesgos verificados

- **Sandbox:** `Scripts/BeLauncher.entitlements` declara Apple Events y Audio Input, pero **no `com.apple.security.app-sandbox`**. El artefacto de hoy no está sandboxeado, lo que hace viable el `shortcuts` CLI y las lecturas locales protegidas por Full Disk Access. Si eso cambia para distribución, N4 y los conectores de Mail/Messages/Notes/Safari se caen y hay que rehacer la arquitectura. Verificar contra el bundle firmado, no contra el repo.
- **N7 verificado (2026-08-08):** no se añadió App Sandbox. BeLauncher abre directamente las bases protegidas de `~/Library/Mail`, `~/Library/Messages`, `~/Library/Group Containers/group.com.apple.notes` y los stores de Safari; el repositorio no usa security-scoped bookmarks ni un helper fuera del sandbox. Full Disk Access (TCC) autoriza esas lecturas, pero no convierte una aplicación sandboxed en una aplicación con acceso arbitrario al sistema de archivos. Por eso el release inspecciona el entitlement firmado y falla si `com.apple.security.app-sandbox=true`. N7 queda **parcial** hasta una migración explícita a bookmarks/helper, seguida de una auditoría separada de distribución.
- **Apple Events:** el consentimiento es por app destino. Sin él, AppleScript devuelve -1743; hay que propagar el error, no reportar éxito.
- **TCC de archivos:** el índice de Safari ya reconoce que `Bookmarks.plist` está detrás de Full Disk Access (`ShortcutIndex.swift:52`). Mail, Messages y Notes igual. No hay security-scoped bookmarks en el repo.
- **Faltan usage keys:** `Scripts/Info.plist` declara Apple Events, audio/micrófono y LSUIElement, pero no Calendar, Contacts ni Photos. N3 los necesita; la presencia de handlers y tests no sustituye la comprobación del bundle firmado en el MacBook.
- **Acciones que no se pueden prometer headless:** `clock.set_alarm`, `screenshot.area`, `facetime.*`, `phone.call`, `home.*`, destinatario de AirDrop, `utility.choose_menu`, `utility.ask_input` son interactivas o dependientes de app. Van con confirmación y foreground intent.
- **`utility.convert_currency` no tiene fuente de tipos de cambio.** No hay API offline. O se conecta un proveedor o se marca `unavailable`; inventar precisión sería peor que no tenerlo.

---

## 5. Delta de los archivos en vuelo (corregido)

La auditoría corrió sobre `de18ca2` y no vio los 16 archivos modificados sin commitear. Error de método: los dos auditores eran de solo lectura y no compilaban, así que aislarlos en worktrees nuevos no aportó nada y les tapó el trabajo más reciente. Delta revisado a mano sobre el diff real. Tres correcciones al inventario de arriba:

**1. El modelo de health de providers es más rico de lo que dice el inventario.**
`Intelligence.swift` ahora distingue `.configured` de `.ready`: credenciales o endpoint local aceptaron una petición de catálogo, pero la generación todavía no está probada. Además valida status HTTP fuera de 2xx, propaga el error del proveedor (incluido dentro del stream SSE) y reporta cuántos caracteres llegaron antes de cortarse. Eso es material para A3: el router ya tiene una señal de tres estados donde el plan asumía dos, y el scoring debe consumir `.configured` como candidato no probado, no como healthy.

**2. Gemini pasó de descriptor a adapter real.**
Endpoint nativo `…/{model}:generateContent` y `:streamGenerateContent?alt=sse`, header `x-goog-api-key`, cuerpo con `contents` y parseo de `candidates`. El paso A1 arranca con un adapter cloud ya hecho, no con tres pendientes.

**3. Descubrimiento de modelos empezó.**
`ModelProviderRegistry` agrega `modelsEndpoint` para Anthropic. El "descubrimiento real de modelos" de A7 ya no parte de cero, aunque sigue faltando para el resto de los proveedores.

**Lo que NO cambia:** la colisión de nombre de `ActionRegistry`, la falta de validación completa de producción para App Intents, la falta de `com.apple.security.app-sandbox` en los entitlements, las usage keys que faltan en `Info.plist`, el veredicto sobre LiteRT-LM y que las 156 acciones no son todas ejecutables hoy. Las piezas de spike MTP/KV y sus tests existen, pero no convierten la integración LiteRT/Metal en producción. Los tres pasos bloqueantes del plan siguen igual.

**Gaps de AI que siguen abiertos:** detección en runtime de Foundation Models, unificación completa de
la frontera de providers, presupuesto real de tokens en retrieval, frescura del health de providers,
auditoría de frontera cloud y la integración auditada de `save`/`forget` en writeback. Las filas A2-A8
siguen siendo trabajo pendiente o parcial; los tests existentes no equivalen a validación de provider
real en el MacBook.

**Sobre TCC:** `Permissions.microphoneStatus` ahora usa `AVAudioApplication` como única autoridad (antes combinaba con `AVCaptureDevice` y eso podía dar una denegación falsa mientras las dos vistas del mismo permiso se acomodaban), y `CapabilityHealth` acepta los checks inyectados para poder testearlos. La sonda de Full Disk Access pasó a `LocalMailConnector.mailRoot` en vez de una ruta `V10` hardcodeada. El riesgo de TCC del plan sigue en pie; lo que cambió es que ahora es verificable con tests.
