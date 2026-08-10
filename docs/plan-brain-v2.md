# Brain v2 — plan de refactor y rediseño

Escrito 2026-08-10, después de auditar el Brain actual en código y G Mirror (el asistente
personal de Jorge) como referencia. Todo lo que sigue está anclado a hechos verificados, no a
intenciones: cada número tiene su archivo o su medición.

---

## 1. De qué partimos, medido

**El chat son 158 líneas.** `Sources/BeLauncher/BrainConversationView.swift` es una barra fija al
pie con un único `@State private var answer` que se pisa en cada pregunta. Sin historial, sin
streaming (aunque `askModel` ya lo soporta con `onFragment`, `askBrain` no lo pasa), sin markdown
(`Text(answer.text)` plano, así que el usuario ve los `**asteriscos**` crudos). Eso es todo lo que
hay hoy entre una persona y "su cerebro".

**El Brain no tiene de dónde recordar.** `graph_enabled` viene en `false` de fábrica en 13 sitios y
lo ha estado desde que la app salió; medido en `docs/PRD-olas-cerebro.md`: **0 nodos, 0 aristas**.
Todo el pipeline de captura, episodios y grafo existe y está apagado.

**Puede actuar, pero no actúa.** `BELActionCatalog.swift` tiene 288 acciones, **170 nativas** de
verdad (archivos, notas, calendario, sistema, recordatorios). Desde el Brain, `runIntent(text)`
solo *escribe el texto en el launcher* para que la persona apriete enter. La única ejecución real
es "misiones", una superficie aparte que casi nadie encuentra.

**El monolito.** `GraphView.swift` son 2.997 líneas con el modelo, el canvas, el overview, las
notas, el inbox, las misiones y el rail de verbos mezclados.

**Tres búsquedas mal unidas.** Fuzzy en RAM, SQLite+vectores, y otra fuzzy que ignora el índice
semántico. Se fusionan con `score: 40 - position` contra scores que van de 10.000 a 101.000, o sea
que el resultado semántico solo aparece cuando el otro no encontró nada.

### Lo que enseña G Mirror

Corre desde hace meses en Hetzner con 7.245 documentos indexados y embebidos. Su tesis, escrita en
`g-mirror-v2.md`: **"la interfaz principal no es el chat"**. El chat es una función; el producto es
el empuje proactivo.

Y su fallo actual es la lección más cara: sus tres crons proactivos —lo único que justificaba el
sistema— llevan días fallando con `credit balance is too low` de la API de Anthropic. **La infra
respira y la función está muerta, por facturación, no por bug.** Un Brain que depende de créditos
por token para su trabajo de fondo se apaga solo el día que nadie mira.

Lo que sí vale copiar: la identidad vive en un archivo recargable (`SOUL.md`), no en código; la
voz está definida por lo que *nunca* hace; y el cliente rápido delega al agente con criterio en vez
de duplicar el prompt en N sitios.

---

## 2. La postura

Jorge pidió "chat como claude.ai". Lo vamos a construir, y bien. Pero el chat es la **puerta**, no
el producto: G Mirror ya diagnosticó en papel que un asistente que espera preguntas se usa tres
días. La diferencia entre esto y otra ventana de chat es que **el Brain empieza la conversación**
cuando tiene algo que decir, y que lo que dice lo puede *hacer*.

Tres decisiones que ordenan todo el plan:

1. **Encender antes que construir.** El pipeline de captura ya existe y está apagado. Ninguna
   fase posterior significa nada sobre un corpus vacío.
2. **El motor es la suscripción que la persona ya paga, no una API por token.** Verificado en la
   máquina de Jorge: `claude -p --output-format stream-json` responde con su sesión de Claude Code
   y emite streaming línea a línea. También hay `codex` con sesión propia, Ollama en 11434 y Gemma
   local en 8998. Esto no es solo ahorro: es lo que evita el `credit balance too low` que tumbó
   G Mirror.
3. **Ejecutar con lo que ya existe.** 170 acciones nativas construidas y probadas. El trabajo no es
   escribir acciones nuevas, es dejar que el modelo las llame.

---

## 3. Fases

Cada fase entrega algo usable y verificable por su cuenta. El orden importa: cada una depende de la
anterior.

### Fase 0 — Encender la captura (sin esto nada más importa)

Hoy el Brain arranca vacío en toda máquina. Hay que decidir y ejecutar el encendido con
consentimiento explícito en el onboarding, no con un default silencioso: la persona elige qué
fuentes entran (correo, notas, calendario, navegador, mensajes) y lo ve.

- Poner el encendido en el onboarding, fuente por fuente, con lo que cada una aporta dicho en una
  línea. Reusar el patrón del paso de Gemma, que ya funciona.
- Arreglar el detector de motor de embeddings que se resuelve **una sola vez por proceso**
  (`BrainSearch.swift:113`): si Ollama arranca después, esa sesión entera se queda sin semántica.
- Unir las tres búsquedas: una sola entrada con la semántica pesando de verdad, no como desempate.

**Verificable**: en una máquina nueva, tras el onboarding, el grafo tiene nodos y la búsqueda
semántica devuelve resultados que el fuzzy no encuentra. Hoy son 0 y 0.

### Fase 1 — El chat de verdad

Reemplazar `BrainConversationView.swift` por una superficie de conversación completa. No es una
mejora del componente: es tirarlo y hacerlo.

- **Hilo persistente**: array de mensajes, no un `answer` que se pisa. Sesiones guardadas en el
  SQLite que ya existe, con títulos automáticos.
- **Streaming**: `askModel` ya acepta `onFragment`; `askBrain` tiene que pasarlo. El trabajo real
  es la vista que pinta token a token sin trabar la ventana.
- **Markdown**: bloques de código con resaltado y copiar, listas, negritas, tablas. Hoy se ven los
  asteriscos.
- **Las citas se quedan.** Lo mejor del chat actual es que cita sus fuentes y distingue las que se
  pueden abrir. Eso no se pierde en la reescritura.
- **Contexto visible**: qué está mirando el Brain para responder, y poder quitárselo.

**Verificable**: una conversación de diez turnos que mantiene el hilo, se reanuda al día siguiente
y renderiza código.

### Fase 2 — El selector de modelo por suscripción detectada

Lo que Jorge pidió: detectar lo que ya está configurado en la máquina y usarlo; pedir auth solo si
no hay nada.

- **Detectar**: CLI de Claude Code (`~/.claude/.credentials.json`), CLI de Codex
  (`~/.codex/auth.json`), Ollama (11434), LM Studio (1234), Gemma local (8998).
- **Transporte nuevo**: hoy `ModelProviderRegistry` conoce `local` y `directKey`. Falta
  `subscriptionCLI`: lanzar el binario como subproceso y leer `stream-json` de su stdout. Esto
  hereda la suscripción sin tocar una API key.
- **El usuario elige**, con el estado real de cada opción a la vista (lista / falta autorizar / no
  instalado). Sin ruleta automática.
- **Lo confidencial nunca sale**: la regla que ya existe (material marcado como confidencial se
  queda en el modelo local) se mantiene por encima de la elección.

**Verificable**: en la máquina de Jorge aparecen las cuatro opciones detectadas y el chat responde
con su suscripción de Claude, sin ninguna clave configurada.

### Fase 3 — Que ejecute, no que dicte

El modelo debe poder llamar a las 170 acciones nativas.

- Exponer el catálogo como herramientas al modelo (el esquema ya está en `BELActionCatalog`).
- **Confirmación por riesgo, no por costumbre**: leer y buscar van solas; escribir, mover, borrar o
  enviar piden un sí explícito, con lo que va a pasar dicho en una línea. La cadena
  `action_drafts` + `BELBrainWriteback` ya implementa exactamente este patrón para la memoria.
- **Recibo**: qué hizo, sobre qué, y cómo deshacerlo. `runMission` ya guarda snapshots por paso.
- Deprecar `runIntent` como camino principal: escribir en el launcher deja de ser la respuesta a
  "haz esto".

**Verificable**: "guarda esto como nota y agéndame revisarlo el viernes" ejecuta las dos acciones,
con una confirmación, y deja recibo.

### Fase 4 — Computer use, en dos capas

Nativo primero, visual como último recurso: es la respuesta de Jorge y es la correcta, porque una
acción nativa es instantánea y gratis mientras que un clic guiado por visión es lento, caro y
frágil.

- **Capa 1** (ya existe): las 170 acciones + Accessibility + App Intents.
- **Capa 2** (nueva): cuando no hay acción nativa, ver la pantalla y operar. El permiso de
  Grabación de pantalla ya se registra bien desde 0.32.72, y hay OCR on-device en `ScreenCapture`.
- Regla dura: la capa 2 solo entra si la 1 no tiene camino, y siempre lo dice antes.

**Verificable**: una tarea en una app sin soporte nativo (ej. un formulario web) se completa por la
capa 2, y la misma tarea en Notas usa la capa 1.

### Fase 5 — Que empiece él la conversación

Es la razón de ser, y es donde G Mirror falló por depender de créditos. Acá corre con el motor
local: sin costo por consulta, sin facturación que se agote.

- El `Daily brief` ya existe con tarjetas accionables. El salto es de resumen a criterio: qué
  cambió, qué se contradice con lo que decidiste antes, qué se va a caer.
- Empujes puntuales cuando pasa algo que importa, no en un horario fijo.
- **La identidad en un archivo recargable**, como el `SOUL.md` de G Mirror: la voz se ajusta
  editando un markdown, no recompilando. Y se define por lo que nunca hace: no resumir cuando toca
  sintetizar, no listar cuando toca decidir.

**Verificable**: durante una semana, el Brain abre conversación por su cuenta con algo que resultó
útil, corriendo con Gemma local y sin costo.

### Transversal — Partir el monolito

`GraphView.swift` (2.997 líneas) se parte por superficie a medida que cada fase la toca, no en un
refactor de una sentada que rompa todo a la vez. La conversación sale primero porque la Fase 1 la
reescribe entera igual.

---

## 4. Lo que este plan NO hace

- **No construye un servidor.** G Mirror vive en Hetzner y por eso puede quedarse sin créditos y
  sin que nadie se entere. Esto corre en el Mac.
- **No replica los siete cerebros de G Mirror.** Dos de ellos (`gmirror-doctrine`, `gmirror-90d`)
  están vacíos o no existen desde hace meses. El corpus local ya tiene fuentes reales.
- **No toca el launcher.** El launcher funciona; esto es el Brain.
- **No promete el cockpit.** El blueprint de G Mirror describe un dashboard de 1.461 líneas que
  nunca se construyó. Acá el equivalente es el Daily brief, que ya existe y solo hay que hacerlo
  bueno.

---

## 5. Riesgos reales

| Riesgo | Por qué es real | Qué lo contiene |
|---|---|---|
| El corpus se enciende y nadie mira lo que capturó | Ya pasó: `graph_enabled=false` desde el día uno, y nadie lo notó hasta auditarlo | Onboarding fuente por fuente, con lo capturado visible desde el primer día |
| El CLI de suscripción cambia su formato de salida | Es una herramienta ajena, no una API estable | Aislar el parseo tras el transporte; caída a `directKey` y a local |
| Ejecutar acciones borra algo | 170 acciones incluyen mover y borrar archivos | Confirmación por riesgo + recibo con cómo deshacer, patrón que ya existe |
| El local no alcanza para conversar bien | Gemma E4B da ~22-25 tok/s en un M4, menos en Macs chicos | El usuario elige; lo proactivo va en local, la conversación puede ir a la suscripción |
| Partir `GraphView` rompe lo que funciona | 2.997 líneas con estado compartido | Partir por superficie a medida que cada fase la toca, con tests antes de mover |

---

## 6. Por dónde empezar

Fase 0 y Fase 1 en paralelo son la mitad del valor: un Brain que tiene qué recordar y una
conversación que se siente como una conversación. La Fase 2 es corta y desbloquea la calidad de
respuesta sin costo por token. Las fases 3 a 5 son las que lo convierten en otra cosa.
