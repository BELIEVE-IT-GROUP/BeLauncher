# Plan Sentient OS -> BeLauncher / BeBrain

**Estado:** ejecución incremental, P0 cerrado en pruebas y P1 en progreso
**Fecha:** 2026-08-08
**Alcance:** arquitectura, UX, captura, conocimiento, acciones, voz, permisos y rendimiento

## Estado de ejecución - 2026-08-08

La dirección sigue siendo válida. Esta es la lectura honesta del código actual; "parcial" significa
que el flujo existe y funciona en casos normales, pero todavía no cumple el contrato arquitectónico
que evita duplicación, estados optimistas o recuperación incompleta.

| Área | Estado | Qué ya funciona | Qué sigue faltando |
|---|---|---|---|
| Brain diario | En progreso | `BrainOverview` con métricas, recientes, Inbox, Pulse, captura real, acciones visibles de nota/importación/voz/pregunta y `dailyBrief` con tres tarjetas (qué cambió / qué importa / qué se puede hacer) más cada señal de Pulse con su propia acción de "preguntarle al Brain", todo en una sola vista | Ejecución de un clic por señal (marcar hecho, asignar dueño) requiere `ActionDraftStore` (propone → aprueba → recibo), que todavía no existe en el repo |
| Viewer / grafo | Funcional | Selección, evidencia, lectura inline, lector con documento correcto, acciones del Inspector dentro de Brain, backlinks explícitos en el Vault y citas navegables cuando existe Markdown local | Pulido final del workspace |
| Notas / Inbox | Parcial fuerte | Nota Markdown, evidencia de audio/importación con ruta original, revisión persistente, propuesta de memoria, reintento de transcripción, filtros por tipo, proyección común `InboxItem` y adjuntos importados en staging UUID+manifiesto con recuperación tras interrupción (`Vault.saveEvidence`, prueba `recoversInterruptedEvidenceImport`) | — |
| Conversación | Funcional | Pregunta con fuentes identificadas, apertura dentro del lector cuando hay documento local, contexto explícito del documento actual, guardar respuesta y convertir en misión; la consulta comparte `BrainCommandCoordinator`, tiene cancelación visible y no puede cerrar una ejecución posterior | Pruebas visuales y pulido final del workspace |
| Misiones | Funcional | Plan, aprobación explícita, borrador persistido, ejecución cancelable, recibo persistido como evidencia, `ActionRunSnapshot` durable con recuperación de interrupciones, historial reciente visible, detalle navegable de pasos/receipt, revisión explícita sin replay y `Outcome Memory` enlazada por misión | Integración visual completa en una Mac limpia |
| Command bar | Funcional | Verbos, comandos `/`, acciones, coordinación y cancelación compartida | Unificar más estados entre launcher y Brain |
| Voz | Parcial | `VoiceProvider` común con Qwen local primero, Apple Speech on-device como fallback, sourcePath/fecha preservados, errores accionables, reintentos del corpus y solicitud de micrófono mediante `AVAudioApplication` | Estado visible de proveedor durante una transcripción y prueba física de permisos/audio |
| Permisos / salud | Funcional | Permisos just-in-time, `AVAudioApplication` para micrófono, MCP health y `CapabilityHealth` compartido con Settings/Onboarding | Pruebas de integración TCC en una Mac limpia |
| Ingesta | En progreso | CorpusRunner, historial de runs, episodios, importadores, checkpoint durable, reintentos por fuente, progreso común durable por fuente, Centro de Fuentes con Mail/Messages/Notes y staging de adjuntos importados ya cubierto por el contrato de Vault | Validar recuperación de ingesta completa en una Mac limpia |
| Rendimiento | Parcial fuerte | Launcher no carga el grafo pesado en la ruta normal, búsqueda de 15.000 bookmarks bajo un frame y baseline automatizado de 10.000 memorias; en esta Mac hay un corpus real de 35 GB; apertura read-only con esquema/nodos/relaciones: 0,33 s, FTS `project`: 0,11 s; proceso debug `launcher-ready`: 206–413 ms y bundle local: 210 ms; el arranque ya no ejecuta la reparación full-table de títulos heredados y las etiquetas del grafo tienen entrada acotada | Medir consultas de pasajes sobre una copia/snapshot y validar cold start en una Mac limpia |
| Modelos locales | Parcial fuerte | Qwen descarga runtime aislado, conserva el detalle real de `stderr` en errores como exit 2, cancela el subprocess `uv/pip` al cancelar la tarea, reanuda una instalación interrumpida y no bloquea el launcher; Ollama/Qwen comparten snapshot durable de fase, paso, bytes, error y timestamp y el contrato común de preflight/clasificación de disco y red; registry común describe transporte, capacidades, descubrimiento, gestión y estado | Probar los mensajes y límites contra providers reales con red cortada y disco bajo; integrar el registry en todos los instaladores |
| P2 llamadas / scheduler | Parcial | Detección sugerida para Zoom/Meet/Teams, selección explícita de audio y scheduler que difiere por ahorro, batería baja, térmica y ventana nocturna | Detección más fiable por fuente y postproceso automático al finalizar una llamada |

### Lectura de prioridad

P0 funcional está cerrado en el código y las pruebas. En P1 ya están cubiertos los contratos de
misiones, recuperación sin replay, historial, revisión explícita y progreso durable por fuente. Lo
que queda es usar el provider registry dentro de todos los instaladores, completar staging para
importaciones/adjuntos y medir el arranque contra una copia del corpus real. La instalación local pesa 35 GB, por
lo que no se debe ejecutar una comprobación destructiva o un `quick_check` sobre la base en uso.
La grabación automática de llamadas sigue deliberadamente desactivada por defecto para evitar
grabaciones silenciosas. La detección ahora busca procesos de conferencia activos aunque no estén
en primer plano, y cualquier fallo de transcripción conserva una evidencia accionable con los
audios locales. El scheduler ya tiene una política observable y los sync manuales no quedan
bloqueados por ella.

## Decisión de producto

BeLauncher sigue siendo la superficie de milisegundos. BeBrain pasa a ser el sistema de
conocimiento operativo detrás de ella. No se reemplaza el grafo ni se copia Sentient OS: se
adoptan sus mejores contratos de producto y se reimplementan dentro de Beacon.

La secuencia que debe funcionar de extremo a extremo es:

```text
capturar -> revisar -> indexar -> entender -> preguntar -> preparar -> aprobar -> actuar -> registrar resultado
```

El grafo es una vista de navegación y diagnóstico. La experiencia principal es el conocimiento
utilizable: leer, conversar, convertir y actuar.

## Matriz de correspondencia

| Sentient OS | Beacon existente | Gap real | Dueño propuesto | Prioridad |
|---|---|---|---|---|
| Home / For You | `BrainOverview`, GraphView, BrainStatusView | `dailyBrief` ya convierte señales de Pulse en acciones preparadas dentro de una sola vista; falta ejecución de un clic (marcar hecho, asignar dueño) | `ActionDraftStore` | P1 |
| Knowledge Viewer | GraphModel, Inspector, CorpusReaderView, BrainWebView | Lectura inline, evidencia y rutas de regreso ya están cableadas; queda pulido final del workspace | `BrainWorkspace` | P0 |
| Reader Markdown | VaultDocument, CorpusDocument, CorpusReaderView | Lector/editor con origen, backlinks y acciones ya existe; falta unificar el último detalle de edición | `BrainDocumentReader` | P0 |
| Grafo accionable | `GraphModel.readHere`, `evidence`, `materializeDocument`, `why` | Capacidades existentes no forman un flujo obvio | `BrainWorkspace` + pruebas UX | P0 |
| Quick capture | Capture, QuickNoteEditorView, ClipboardWatcher | Capturas y notas llegan al Inbox; evidencia pendiente de voz y clips fijados conservan procedencia sin duplicar el corpus; archivos importados mantienen su ruta original | `CaptureCoordinator` | P0 |
| Iterative connectors | CorpusRunner, BrowserHistory, Importers, Episodes | Checkpoints, reintentos y salud no están unificados | `IngestionRunStore` | P1 |
| Vault staging | Vault, CorpusFiles, Database | CorpusFolder, Vault e importaciones/adjuntos usan staging con UUID, manifiesto durable, recuperación al iniciar y confirmación multiarchivo; hay prueba de reapertura tras interrupción para memoria, quick notes y evidencia importada | Cerrado | P1 |
| Proactive cards | Pulse, Autopilot, OutcomePack, Mission | Falta una cadena clara de propuesta -> aprobación -> recibo | `ActionDraftStore` | P1 |
| Command bar / Sidekick | LauncherModel, CommandPanel, AgentRunner | Varias superficies deben compartir un solo run y cancelación; MCP stdio ya responde antes de descubrir modelos y marca rutas antiguas como desconectadas | `BrainCommandCoordinator` | P0 |
| Native voice | AudioCaptureController, Transcription, CallCaptureController | Qwen no puede ser requisito de dictado básico | `VoiceProvider` | P0 |
| Permission health | Permissions, SettingsView, MCPHealth | Estados y acciones no siempre representan la realidad del sistema | `CapabilityHealth` | P0 |
| Overnight processing | CorpusRunner background path | Política de defer por energía, batería baja y térmica ya observable; faltan ventanas nocturnas | `BrainScheduler` | P2 |
| Local model lifecycle | ModelInstaller, QwenASR, LocalModels | Registry, descubrimiento, gestión y estado unificados; faltan progreso común y diagnóstico de red/espacio | `ModelProviderRegistry` | P1 |

## Arquitectura objetivo

### Procesos y responsabilidades

1. **Launcher UI:** hotkey, búsqueda rápida, clipboard carousel, verbos y comandos cortos. No
   carga el corpus completo, el grafo, embeddings ni runtimes externos durante el arranque.
2. **Brain coordinator:** orquesta búsquedas, capturas, conversaciones y acciones; expone estado
   observable a Launcher y Brain.
3. **Ingestion workers:** leen fuentes, normalizan artefactos, avanzan checkpoints y escriben
   resultados idempotentes.
4. **Memory store:** conserva evidencia, memoria extraída, memoria confirmada y resultados.
5. **Action engine:** prepara planes, solicita aprobación, ejecuta una única misión y registra un
   recibo verificable.
6. **Model providers:** OpenAI, Ollama, LM Studio, Apple Speech y Qwen opcional detrás de una
   interfaz común.

### Contratos que deben existir antes de ampliar funciones

```swift
struct EvidenceRecord
struct MemoryRecord
struct ActionDraft
struct ActionRun
struct ActionReceipt
struct IngestionCheckpoint
enum CapabilityState
```

Cada registro debe incluir identificador estable, fuente, fecha, nivel de verdad, provenance y
estado de borrado. Una ejecución larga debe poder cerrarse y reanudarse sin duplicar ni saltar
elementos.

## Plan por fases

### P0 - Hacer que el Brain sea utilizable

- Unificar grafo, inspector, lector, conversación y acciones en una ventana `BrainWorkspace`.
- Al seleccionar un nodo, cargar siempre contenido real, evidencia, origen y fecha.
- Eliminar rutas que abren ventanas secundarias vacías.
- Añadir `Inbox` para Quick Notes, clipboard, audio, archivos y transcripciones.
- Crear nota desde `+`, carpeta, clipboard, selección y comando natural.
- Añadir editor de misión: intención, contexto, pasos, aprobación y resultado.
- Compartir un `CommandRun` entre launcher, Brain, acciones y cancelación.
- Usar dictado nativo como baseline; Qwen queda como provider opcional.
- Crear panel de salud con permisos y modelos reales, no estados escritos en preferencias.

**Aceptación:** un usuario nuevo puede capturar una nota, encontrarla, leerla, preguntar sobre
ella, convertirla en misión y ejecutarla sin abrir otra aplicación ni entender Python.

### P1 - Convertir conocimiento en trabajo diario

- `BrainHomeView` con Hoy, recientes, pendientes, cambios y acciones preparadas.
- Tarjetas con explicación de por qué aparecen, fuentes y confianza.
- Edición de drafts antes de enviar o ejecutar.
- Receipts y `Outcome Memory` después de cada acción.
- Checkpoints por fuente, reintentos, pausa, progreso durable e historial.
- Actualización Markdown mediante staging y swap atómico.
- Snippets accionables: copiar, pegar, insertar, editar y convertir en nota.
- Conversación con citas, silencio honesto y acciones convertibles.

**Aceptación:** el Brain no solo muestra nodos; entrega contexto útil y una acción preparada que
el usuario entiende antes de aprobar.

### P2 - Automatización controlada

- Scheduler nocturno con límites de energía, temperatura y batería; la política ya existe, falta
  probar el ciclo real y su observabilidad en una Mac limpia.
- Detección de llamadas y selección explícita de Zoom, Meet y Teams.
- Procesamiento automático de audio al finalizar una llamada.
- Wake helper solamente después de tener observabilidad y deadman probados.
- Conectores adicionales y sincronización MCP con estado de cifrado y reintento.
- Agentes especializados sobre el mismo `ActionEngine`, no procesos paralelos sin contrato.

## Reglas de UX

- El primer viewport debe responder: qué sabe el Brain, qué cambió y qué puedo hacer ahora.
- Cada botón debe tener efecto visible o explicar exactamente el bloqueo.
- El grafo nunca puede ser el único resultado: siempre debe existir lectura o evidencia.
- Las acciones destructivas requieren aprobación explícita y recibo posterior.
- Los estados de instalación se expresan en lenguaje de usuario; los detalles técnicos viven en
  Diagnóstico.
- Una nota, misión o acción debe tener un lugar claro donde escribir antes de aparecer como botón.
- Toda ventana nueva debe abrir con contenido, contexto y ruta de regreso.

## Rendimiento y seguridad

- Presupuesto de apertura del launcher: objetivo medido en milisegundos, sin esperar indexación.
- Búsqueda rápida degradable a texto mientras el embedding está ausente.
- Corpus pesado, grafo y modelos fuera del camino crítico de activación.
- PII guardado con política explícita y borrado completo del índice, grafo y disco.
- Exclusión por aplicación, sitio, carpeta y tipo de fuente.
- Logs sin contenido privado por defecto.
- Ningún proveedor cloud se usa si el usuario no lo habilita.
- No portar código de Sentient OS: el repositorio es AGPL-3.0; solo se portan ideas y contratos.

## Secuencia inmediata de implementación

1. Congelar contratos `EvidenceRecord`, `MemoryRecord`, `ActionDraft`, `ActionRun` y
   `ActionReceipt`.
2. Auditar los flujos actuales de `GraphModel` e `Inspector` con pruebas de integración de UI.
3. Construir `BrainWorkspace` usando las piezas existentes, sin duplicar stores.
4. Cablear Inbox -> Memory -> Reader -> Conversation -> Mission.
5. Extraer `VoiceProvider` y dejar Apple Speech como fallback obligatorio.
6. Crear `CapabilityHealth` y sustituir estados optimistas de Settings/Onboarding.
7. Medir arranque con corpus grande antes y después de cada cambio.
8. Solo después implementar Home proactivo, scheduler y llamadas automáticas.

## Criterios de salida de la primera entrega

- Todas las entidades visibles del grafo tienen una ruta de lectura real.
- Crear una nota no requiere descubrir una pantalla oculta.
- Una pregunta muestra evidencia y puede convertirse en acción.
- Una misión tiene editor, aprobación, ejecución y recibo.
- Dictado funciona sin Qwen instalado.
- Cerrar la app durante ingestión permite reanudarla.
- Abrir el launcher no espera al Brain ni al corpus.
- Los tests de recuperación, grafo, permisos, captura y rendimiento pasan en un Mac limpio.
