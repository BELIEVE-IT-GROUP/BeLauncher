# Ola 1: auditoria UX del Brain y del Launcher

Estado: **en curso**.

## Criterio humano

Una persona debe poder llegar a estas acciones sin conocer RAG, vectores, chunks, schemas ni
IDs: buscar algo, escribir una nota, importar un archivo, dictar, preguntar al Brain, revisar el
Inbox, leer/editar Markdown, preparar una misión y abrir la fuente original.

## Primer corte entregado

- La navegación del Brain muestra claramente `Overview`, `My notes` y `Graph` con selección visible.
- La barra lateral deja de empezar con jerga técnica y muestra estado local, privacidad y conteos
  comprensibles.
- El Overview usa `Remembered`, `Connections`, `Notes`, `Brain updates`, `Where your Brain looks`,
  `Worth your attention`, `Recent notes` y `Recent work`.
- El Overview ofrece acciones directas para nueva nota, importar archivo, nota de voz, preguntar y
  planear una tarea.
- La conversación con el Brain vive abajo como una barra de comando persistente; el contenido,
  Inbox y grafo ocupan primero la superficie principal, como una herramienta de trabajo y no como
  un chat que desplaza todo lo demás.
- La escalera técnica de niveles de verdad permanece disponible dentro del inspector, donde sirve
  para revisar evidencia, pero no compite con la navegación principal.

## Recorridos que deben cerrarse en los siguientes cortes

1. Nueva nota: abrir, escribir, guardar Markdown, encontrarla después y editarla.
2. Inbox: entender por qué algo está pendiente, transcribirlo, revisarlo, convertirlo en memoria o
   descartarlo.
3. Brain: preguntar en lenguaje natural, ver la respuesta con fuentes y abrir la evidencia sin
   ventanas vacías.
4. Misión: expresar una intención, revisar el plan, aprobarla y leer el recibo.
5. Fuentes: saber qué se lee, qué no se lee, cuándo se sincronizó y qué permiso falta.
6. Launcher: usar clipboard, snippets, verbos, nota rápida, voz y dictado sin perder el foco.

## Regla de la ola

Cada capacidad visible debe tener un camino de entrada, un estado mientras trabaja, un resultado
que se pueda inspeccionar y un error que indique la siguiente acción. Una etiqueta o un contador no
cuentan como UX terminada si no llevan a una operación real.

El Inbox ya ofrece la bifurcación explícita `Keep in Brain` o `Mark as reviewed`. La primera usa la
propuesta de memoria existente y conserva la confirmación humana; la segunda limpia la cola sin
convertir el contenido en memoria.

## Segundo corte: misiones desde el Brain

El botón `Plan a task` ya no dispara una orden ambigua hacia el Launcher. Abre un compositor dentro
del Brain donde la persona escribe la intención en lenguaje natural. `Show plan` la entrega al
catálogo real de `MissionPlanner`; si no existe una capacidad compatible, el diálogo lo dice y no
crea una misión falsa. Cuando sí existe, se abre el flujo ya implementado de plan, aprobación,
ejecución y recibo.

Esto conserva el límite de confianza: escribir una misión no ejecuta nada, y el plan se puede leer
antes de que una acción cambie el Mac.

## Primer corte del Launcher

El carrusel conserva todos los clips retenidos por el almacén y se puede recorrer horizontalmente;
los quick actions de BeBrain permanecen encima cuando se abre la superficie normal. Los atajos
numéricos de las tarjetas solo se muestran en el modo dedicado de portapapeles, donde realmente
están conectados al teclado. En la vista mixta no se promete una tecla que podría ejecutar otra
fila.

La barra de comando también muestra un botón de icono para abrir las acciones de la selección
actual. `⌘K` sigue siendo el camino rápido, pero ya no es un requisito oculto para descubrirlas.

Los snippets dejaron de depender de recordar una palabra clave: el footer tiene una entrada
`Snippets` que abre `/snippet`, lista los guardados, permite inspeccionar su expansión y ejecuta el
snippet seleccionado con Enter, incluyendo su posición `{cursor}`.

Las frases naturales que no son un comando cerrado ya no terminan en un vacío silencioso: si parecen
una pregunta o una petición, aparece `Ask your Brain about…` y Enter las manda al buscador semántico
local. El Launcher muestra la respuesta en la misma superficie; no ejecuta una acción de sistema por
inferirla.

El panel de Quick Actions identifica el elemento seleccionado, separa las acciones por contexto y
expone un campo inequívoco para filtrar esa lista. El botón visible y `⌘K` abren el mismo panel.

Los verbos de IA también aceptan lenguaje cotidiano: `resume esto`, `corrige lo que copié`,
`traducir esto` y equivalentes usan el último texto copiado como contexto y aparecen como una fila
ejecutable. Los flujos y atajos creados por la persona conservan prioridad si usan la misma palabra.

Cuando el verbo no tiene texto disponible, el Launcher abre un compositor propio para escribir o
pegar el contenido. Ya no exige haber copiado algo antes ni deja que el verbo falle sobre una entrada
vacía.

Un término sin resultados ofrece ahora `Ask your brain` con la misma frase, en lugar de dejar a la
persona solo con ejemplos técnicos. En el Brain, cada fuente disponible o manual tiene un acceso
directo a Ajustes; las fuentes planificadas siguen marcadas como tales y no prometen una conexión.

## Wave 2: Shortcuts

Los atajos de macOS ya no dependen de recordar el nombre exacto: el footer tiene una entrada
`Shortcuts` que abre `/shortcuts`, muestra los atajos que macOS reporta en esta máquina y permite
seleccionarlos, leer su detalle y ejecutarlos con Enter. La ejecución sigue pasando por la compuerta
de permisos y confirmación existente.

### Inspección completa del clip

Una miniatura no basta para saber qué se copió. Cada tarjeta ofrece ahora un estado hover
reconocible y una acción `Quick Preview` que expande el contenido completo dentro del Launcher, sin
cerrarlo ni reemplazar el contenido del portapapeles. El preview reutiliza el detalle real y funciona
para texto largo, imágenes y archivos, junto con las acciones existentes de la tarjeta.

## Wave 2: Reminders

Reminders deja de aparecer como una promesa vacía. La primera entrega conecta el permiso real de
EventKit con el catálogo BEL y permite leer solo los recordatorios pendientes, buscar por título o
lista y abrir `/reminders` desde el launcher. Settings muestra el estado `Allow`/conectado y el
bundle explica por qué se solicita el permiso.

La entrada es deliberadamente de solo lectura: buscar no modifica nada y Enter copia el recordatorio
seleccionado. Crear, completar, editar y borrar quedan fuera de este corte hasta tener sus propios
tests de confirmación y recibo; siguen marcados como no disponibles en el catálogo.

## Wave 2: Contacts

Contacts tiene ahora un puente de lectura local mediante `Contacts.framework`: Settings muestra el
permiso, `/contacts` lista la libreta y una búsqueda por nombre, correo o teléfono devuelve un
resultado que se puede inspeccionar y copiar. Crear, editar y compartir contactos siguen fuera de
este corte para no convertir una lectura en una mutación sin confirmación.

## Wave 2: Photos

Photos se conecta mediante `Photos.framework` con permiso de lectura. `/photos` muestra metadatos
locales sin descargar originales, y Enter abre Fotos; la búsqueda BEL devuelve el conteo real de
elementos disponibles. Los identificadores de Photos no se presentan como rutas de Finder ni como
previews falsos. Edición, álbumes y extracción de texto quedan pendientes de adapters con recibo.
