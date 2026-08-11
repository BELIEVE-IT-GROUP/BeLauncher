# El Brain, desde cero

Este documento reemplaza `plan-brain-v2.md`. Aquel proponía arreglar el destilado de episodios, unir
las búsquedas y mejorar el chat. Todo eso era cierto y todo eso era insuficiente: son parches sobre
una estructura equivocada. Esto empieza por la estructura.

Escrito 2026-08-11, después de auditar el Brain en código, su corpus real en la máquina de Jorge,
G Mirror (asistente personal de Jorge) y Skales (referencia que Jorge trajo).

---

## 1. El error de origen

**El Brain se organiza por lo que sabe de ti. Debería organizarse por lo que hace por ti.**

Eso no es una diferencia de énfasis, es la causa de todo lo demás. Un sistema organizado alrededor
de su conocimiento produce, inevitablemente, una pantalla que muestra ese conocimiento: nodos,
aristas, episodios, entidades, inbox. Es una vista de base de datos con nombre de cerebro.

De ahí salen las tres quejas, y no son tres problemas sino uno:

| Lo que se siente | De dónde sale |
|---|---|
| "UI llena de info cero relevante" | La pantalla principal muestra el estado interno del índice, no algo que le sirva a la persona hoy |
| "Botones que no llevan a nada" | No hay nada detrás que ejecutar: el Brain manda el texto al launcher y se lava las manos |
| "MD de tres líneas con basura cero accionable" | Destila lo único que capturó: actividad. Un dominio visitado 40 veces se convierte en un "Proyecto" |

Y de ahí sale la distancia entre la landing y el producto. La landing promete un cerebro que
entiende tu trabajo. El producto entrega un visor de lo que tocaste.

### La comparación que lo deja claro

Skales tiene **70 herramientas** en un solo orquestador (`orchestrator.ts`), páginas llamadas
*tasks*, *planner*, *autopilot*, *schedule*, y una que se llama *memory* — una sola, y no es la
principal. La memoria es un insumo.

El Brain tiene *overview*, *graph*, *inbox*, *notes*, *reader*: cinco superficies, todas sobre el
mismo corpus, ninguna sobre qué hacer con él. Y 158 líneas de chat al pie.

G Mirror llegó a la misma conclusión por su cuenta y la dejó escrita: *"la interfaz principal no es
el chat"*. Su producto es el empuje proactivo. Lo que le falló no fue la idea sino el sostén: sus
crons murieron por créditos de API agotados.

---

## 2. Qué es el Brain, en una frase

> Un colega que conoce tu trabajo, te dice lo que importa antes de que preguntes, y hace lo que
> hablaron.

Tres verbos, en orden de dificultad y de valor: **conocer, decir, hacer**. Todo lo que no sirva a
uno de los tres no va.

Las pruebas de que existe, que son también los criterios de aceptación:

1. Alguien lo abre por la mañana y encuentra algo que no sabía y le sirve. (decir)
2. Le pide algo en una frase y queda hecho, sin que tenga que abrir otra app. (hacer)
3. A la semana siguiente sigue abriéndolo. (las dos, sostenidas)

Hoy no pasa ninguna de las tres.

---

## 3. Qué se borra

Deconstruir es borrar, no reordenar. Esto es lo que se va:

- **El grafo como pantalla.** Force-graph, canvas, inspector, correcciones de merge, atajos de
  teclado sobre nodos. Es la superficie más cara del Brain (`GraphView.swift`, 2.997 líneas, más
  `brain.html` y `GraphPainter.swift`) y la que menos le dice a nadie. El grafo puede seguir
  existiendo como estructura interna; deja de ser algo que una persona mira.
- **Las entidades de dominio.** 51 de 195 nodos son sitios web etiquetados como "Proyecto". Un
  archivo entero del vault dice, completo: *"bechat.believe-global.com — Proyecto · visto 40
  vez(es)"*. Eso no se arregla, se elimina.
- **Los episodios por tramo de reloj.** 110 minutos de ventanas en foco no son un episodio. Si no
  tiene asunto, no existe.
- **El inbox como superficie.** Es la bandeja de lo que el sistema no supo clasificar, presentada
  como trabajo de la persona. G Mirror lo dice mejor que nadie en su propio vault: *"vaciarlo es el
  trabajo, no llenarlo"*.
- **`runIntent` como respuesta a una orden.** Escribir el texto en el launcher para que la persona
  apriete enter no es hacer, es delegar de vuelta.

Se queda, porque tiene sustancia comprobada: los **663 pasajes con contenido real** (de 836), casi
todos conversaciones; el índice semántico; las **170 acciones nativas**; el vault en Markdown que la
persona posee; y las citas con fuente abrible del chat actual, que es lo mejor que tiene.

---

## 4. La forma nueva

Cuatro piezas. Ninguna es una pestaña sobre el corpus.

### 4.1 Hoy — lo que ve al abrir

Una sola pantalla que responde *"¿qué necesito saber ahora?"*. No contadores, no estado del índice,
no "0 nodos". Tarjetas con algo que pasó y qué hacer al respecto, cada una con su acción al lado.
Si no hay nada que decir, lo dice y ocupa dos líneas: un colega que no tiene noticias no te hace
leer un tablero.

El `Daily brief` ya existe con tarjetas accionables. Es el único cimiento reusable de la UI actual.

### 4.2 Conversación — la puerta

Chat de verdad: hilo persistente, streaming, markdown, código. Con dos cosas que un chat genérico no
tiene: **cita sus fuentes** (ya funciona hoy y se conserva) y **ejecuta lo que dice**.

### 4.3 Capacidades — lo que puede hacer, y solo eso

Robado de Skales (`capabilities.ts`), y es el patrón que más problema resuelve: un **registro vivo**
que se reconstruye del estado real —qué está instalado, autorizado, conectado— y se inyecta en el
prompt del modelo. El asistente nunca ofrece lo que no puede cumplir, y la interfaz nunca muestra un
botón sin nada detrás.

Es la cura estructural de "botones que no llevan a nada": deja de ser un problema de disciplina al
programar y pasa a ser imposible por construcción.

### 4.4 Trabajo de fondo — lo que hace sin que mires

De Skales (`autopilot.ts`): perfil de la persona → objetivos → plan → tareas → cron. De G Mirror: la
identidad en un archivo recargable, y la voz definida por lo que *nunca* hace.

Corriendo con el motor local, que ya funciona y ya está medido: 22-25 tok/s en la GPU de un M4. Sin
costo por consulta y sin facturación que se agote — que es exactamente lo que mató la parte
proactiva de G Mirror con la infraestructura viva.

---

## 5. De dónde sale lo que sabe

El corpus no se arregla mejorando el destilado. Se cambia qué se considera digno de recordar.

**Hoy captura actividad**: apps en foco, dominios visitados, tramos de tiempo. Es lo fácil de
capturar y lo que menos significa.

**Debe capturar compromisos y decisiones**: lo que dijiste que ibas a hacer, lo que decidiste y por
qué, lo que alguien espera de ti, lo que cambió respecto a lo que creías. Eso vive en
conversaciones, correos y reuniones — las fuentes que ya tienen contenido real.

Prueba para admitir cualquier cosa al corpus: **si no se puede decir en una frase por qué le
importaría a la persona dentro de un mes, no entra.** Un dominio visitado no pasa esa prueba. Un
"le dijiste al cliente que el viernes" sí.

### Y antes que todo lo demás

48 pasajes contienen `license_key`, `api_key`, `password` o `sk-`. Uno es un clip del portapapeles
con claves de licencia de BeLauncher y correos de clientes, indexado y buscable. Filtro al capturar
y purga de lo ya indexado. Esto no espera a ninguna fase.

---

## 6. Cómo se construye

Sin olas de seis meses. Cada paso deja algo que se puede usar y juzgar.

| # | Qué | Cómo se sabe que sirvió |
|---|---|---|
| 1 | Purga de secretos + filtro al capturar | Ningún pasaje contiene una clave |
| 2 | Registro vivo de capacidades | Ninguna acción ofrecida falla por no estar configurada |
| 3 | Chat con hilo, streaming, markdown y ejecución de las 170 acciones | Una petición en una frase queda hecha, con confirmación y recibo |
| 4 | Corpus de compromisos y decisiones, sin dominios ni tramos de reloj | Cada nodo se puede leer en voz alta y significa algo |
| 5 | "Hoy" reemplaza al overview; el grafo sale de la UI | Al abrir se ve algo útil, no el estado del índice |
| 6 | Trabajo de fondo con motor local | Una semana en que abre conversación por su cuenta y acierta |

El orden no es negociable en un punto: **3 no va antes que 1**, y **5 no va antes que 4**. Un chat
excelente sobre un corpus de dominios visitados responde con más convicción cosas que no sabe.

---

## 7. Lo que este documento se prohíbe

G Mirror tiene un blueprint de 1.461 líneas cuyo componente central —el cockpit— nunca se
construyó. Ese es el fracaso a evitar, y no se evita escribiendo mejor: se evita construyendo el
paso 1 antes de escribir el paso 7.

Por eso acá no hay cronograma, no hay arquitectura de referencia, y no hay nombres de módulos que
todavía no existen. Hay seis pasos, cada uno con una prueba que se puede fallar.

---

## 8. Lo que falta decidir contigo

1. **El grafo fuera de la UI.** Es la superficie más grande que se borra. ¿De acuerdo, o hay algo
   ahí que sí usas?
2. **Alcance fuera de la app.** Skales llega por Telegram y WhatsApp. BeLauncher hoy vive en la
   barra de menú. ¿El Brain debería alcanzarte fuera del Mac?
3. **Qué prueba primero.** Los pasos 1 y 2 son higiene; el 3 es lo que se siente. ¿Empezamos por lo
   que se siente aunque el corpus siga pobre, o por el corpus?
