# Ola 1: auditoria UX del Brain y del Launcher

Estado: **completada en código; pendiente únicamente de validación visual en el MacBook de
release**.

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

## Recorridos cerrados en esta ola

1. Nueva nota: abrir, escribir, guardar Markdown, encontrarla después y editarla.
2. Inbox: entender por qué algo está pendiente, transcribirlo, revisarlo, convertirlo en memoria o
   descartarlo sin borrar el audio/origen.
3. Brain: preguntar en lenguaje natural, ver la respuesta con fuentes y abrir la evidencia real.
4. Misión: expresar una intención, revisar el plan, aprobarla y leer el recibo.
5. Fuentes: saber qué se lee, qué no se lee, cuándo se sincronizó y qué permiso falta.
6. Launcher: usar clipboard, snippets, verbos, nota rápida, voz y dictado sin perder el foco.

El descarte de Inbox elimina solo el sobre Markdown de triage y conserva la procedencia. Los
errores de revisión y guardado se muestran en la misma superficie. El flujo de conservar clipboard
usa el texto seleccionado real, no un literal fijo.

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

Una miniatura no basta para saber qué se copió. Cada tarjeta muestra una acción `Quick Preview`
visible y también abre el detalle al mantener el cursor 160 ms sobre ella (con cancelación al salir). El contenido completo se expande dentro del Launcher, sin
cerrarlo ni reemplazar el contenido del portapapeles. El preview reutiliza el detalle real y funciona
para texto largo, imágenes y archivos, junto con las acciones existentes de la tarjeta.

## Wave 2: Reminders

Reminders deja de aparecer como una promesa vacía. La primera entrega conecta el permiso real de
EventKit con el catálogo BEL y permite leer solo los recordatorios pendientes, buscar por título o
lista y abrir `/reminders` desde el launcher. Settings muestra el estado `Allow`/conectado y el
bundle explica por qué se solicita el permiso.

La búsqueda no modifica nada y Enter copia el recordatorio seleccionado. Además, `/reminder comprar
leche` abre una intención explícita y, tras confirmación, crea el recordatorio en EventKit. Un
recordatorio seleccionado ofrece `Complete reminder`; la acción está detrás del gate central `r2`,
por lo que ninguna ruta puede completarlo silenciosamente. Crear y completar refrescan el snapshot,
actualizan la proyección del Brain y dejan un recibo con el identificador de EventKit. `Change due date`
abre un campo explícito que acepta `tomorrow 09:00`, `today 15:30` o `yyyy-MM-dd HH:mm`, pide confirmación
antes de escribir en EventKit y refresca el recordatorio después del guardado. Una fecha inválida no
se interpreta ni se ejecuta.
Para consultar una lista concreta sin crear nada, `/reminders list Trabajo` es una orden distinta:
lee solo los recordatorios pendientes de esa lista y devuelve un recibo de lectura.
También se puede crear una lista desde el mismo lenguaje explícito con `/reminders new list Proyectos`.
La app rechaza nombres vacíos o duplicados, pide confirmación antes de escribir en EventKit, devuelve
el identificador de la lista creada y refresca Reminders y su proyección del Brain.
Los recordatorios completados no contaminan la búsqueda diaria ni el Brain: aparecen solo con
`/reminders completed`. Desde ahí `Undo completion` pide confirmación, vuelve a marcar el elemento
como pendiente en EventKit y lo devuelve a la lista normal.
Un recordatorio seleccionado también permite añadir notas, moverlo a otra lista o cambiar su
prioridad. También puede eliminarse desde la sección `Danger`; borrar nunca es la acción primaria y
requiere una confirmación separada. Cada operación muestra un resumen, pide confirmación, guarda
mediante EventKit y vuelve a leer la fuente antes de reportar el resultado.

## Wave 2: Contacts

Contacts tiene ahora un puente de lectura local mediante `Contacts.framework`: Settings muestra el
permiso, `/contacts` lista la libreta y una búsqueda por nombre, correo o teléfono devuelve un
resultado que se puede inspeccionar y copiar. Un contacto seleccionado ofrece detalle completo,
copia del email o teléfono asociado y `Open contact` selecciona la ficha exacta en Contacts usando
su identificador estable. La primera apertura puede pedir Automatización para BeLauncher; un
bloqueo del sistema se muestra como error accionable, no como éxito. `Edit contact` usa el mismo
identificador estable. La edición
abre nombre, email y teléfono; los campos vacíos conservan su valor actual. Requiere confirmación
`r2`, escribe con `CNSaveRequest`, deja recibo y refresca Contacts y su proyección operativa del
Brain. Compartir el contacto y abrir una ficha concreta fuera de BeLauncher siguen pendientes.
`/contact add Ada Lovelace` es la única entrada de creación: requiere permiso, confirmación y escribe
mediante `CNSaveRequest`, dejando recibo local y refrescando el snapshot.

## Wave 2: Photos

Photos se conecta mediante `Photos.framework` con permiso de lectura. `/photos` muestra metadatos
locales sin descargar originales, y Enter abre Fotos; la búsqueda BEL devuelve el conteo real de
imágenes y videos. También entiende criterios deterministas como fecha, favoritos y video. El
detalle conserva el identificador estable, dimensiones y tipo sin convertirlo en una ruta de
Finder ni descargar un original. Un resultado seleccionado ofrece `Add to album` y `Create album
with photo`: pide el nombre exacto, confirma el cambio y usa `PHAssetCollectionChangeRequest` para
trabajar por `localIdentifier`. No crea un álbum duplicado silenciosamente. También ofrece `Extract
text from photo`, que carga el asset autorizado en memoria y usa Vision local con español e inglés;
no persiste una copia ni envía la imagen a un modelo. Cada operación deja recibo. Abrir un asset
concreto dentro de Photos sigue pendiente porque el esquema público no ofrece un deep link estable
para ese `localIdentifier`. `Keep in Brain` es la entrada selectiva: solo aparece con el Brain
activado, pide confirmación y guarda metadata más la referencia `bel://photos/...`; la fototeca
completa no se proyecta automáticamente.

## Permisos de Wave 2

Reminders, Contacts y Photos ya no son conexiones escondidas solo en Settings. La guía de inicio
las muestra como permisos opcionales con lenguaje humano, usa el estado real del sistema para pintar
`Granted`, y refresca el estado cuando la persona vuelve desde Privacy & Security. El Brain y el
centro de fuentes mantienen el mismo estado y la misma acción `Allow`. El estado `Connected` ahora
requiere además una lectura local exitosa: timestamp, cantidad leída y ningún error persistido.
Conceder permiso sin haber leído la fuente sigue mostrando `Available`, no un falso positivo.
Si el permiso ya existía antes de abrir la app, los snapshots de estas fuentes se calientan después
del arranque, fuera del camino crítico del launcher; no hace falta volver a pulsar `Allow`.

El footer del Launcher también tiene ahora `Sources`: un menú descubrible que lleva a `/reminders`,
`/contacts` y `/photos`. La persona puede encontrar estas fuentes con el ratón o el teclado sin
aprender comandos internos.

En Settings, `Refresh` para estas tres fuentes actualiza su snapshot local y devuelve feedback
explícito. No se enruta por el corpus runner existente: la ingestión de Reminders, Contacts y
Photos al grafo sigue siendo una próxima capa, no una promesa escondida detrás de un botón.

Contacts sí tiene una primera proyección al Brain: al actualizar la fuente, los nombres y el primer
dato de contacto útil se convierten en nodos `Person` sin duplicar la libreta ni afirmar que el
Brain es el origen. Photos permanece fuera del grafo y Reminders conserva su modelo de pendientes.
Los nodos de Contacts llevan un identificador de fuente estable y se retiran si la lectura posterior
ya no devuelve ese contacto; no se mezclan con personas descubiertas en reuniones.
Los recordatorios pendientes también se proyectan como `Commitment` operativos al actualizar la
fuente; no entran como memoria confirmada y su fuente sigue siendo Reminders.
Los compromisos que ya no devuelve una lectura autorizada se retiran solo si llevan el prefijo de
Reminders; un fallo de lectura nunca dispara esa limpieza.
Contacts y Reminders conservan además una referencia estable `bel://` en cada nodo. En el inspector
del grafo, `Read here` materializa la representación Markdown del Brain y `Open source` abre la app
nativa correspondiente; ya no aparece una segunda ventana vacía por no tener `target`.
