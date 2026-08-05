# BeLauncher — manual de uso

Este manual está escrito para que puedas hacer cosas, no para enumerar funciones. Si buscas algo
concreto, ve al índice. Si es tu primer día, lee los dos primeros capítulos y ya sabrás usarlo.

Todo lo que se describe aquí funciona sin cuenta, sin servidor y sin que nada tuyo salga de tu Mac,
salvo tres cosas que decides tú y que están señaladas cuando aparecen.

---

## Índice

1. [Los cinco primeros minutos](#1-los-cinco-primeros-minutos)
2. [Buscar y abrir](#2-buscar-y-abrir)
3. [El portapapeles](#3-el-portapapeles)
4. [Snippets: texto que se escribe solo](#4-snippets-texto-que-se-escribe-solo)
5. [Flujos: varias cosas de un tirón](#5-flujos-varias-cosas-de-un-tirón)
6. [Calcular y convertir](#6-calcular-y-convertir)
7. [Comandos del sistema y ventanas](#7-comandos-del-sistema-y-ventanas)
8. [Inteligencia: elegir quién responde](#8-inteligencia-elegir-quién-responde)
9. [Pedirle cosas escribiendo](#9-pedirle-cosas-escribiendo)
10. [Leer la pantalla](#10-leer-la-pantalla)
11. [Intenciones: decir qué quieres, no qué herramienta abrir](#11-intenciones)
12. [Encargos con «/»](#12-encargos-con-)
13. [Lienzos](#13-lienzos)
14. [Misiones que corren solas](#14-misiones-que-corren-solas)
15. [Tu cerebro](#15-tu-cerebro)
16. [Memoria de trabajo](#16-memoria-de-trabajo)
17. [Rutinas detectadas solas](#17-rutinas-detectadas-solas)
18. [Que aprenda cómo trabajas](#18-que-aprenda-cómo-trabajas)
19. [Equipo](#19-equipo)
20. [Conectarlo a Claude o ChatGPT](#20-conectarlo-a-claude-o-chatgpt)
21. [Permisos, uno por uno](#21-permisos-uno-por-uno)
22. [Privacidad: qué sale y qué no](#22-privacidad-qué-sale-y-qué-no)
23. [Tus datos: dónde están y cómo te los llevas](#23-tus-datos)
24. [Licencia y equipos](#24-licencia-y-equipos)
25. [Actualizaciones](#25-actualizaciones)
26. [Cuando algo no funciona](#26-cuando-algo-no-funciona)
27. [Todos los atajos](#27-todos-los-atajos)
28. [Desinstalar del todo](#28-desinstalar-del-todo)

---

## 1. Los cinco primeros minutos

**Abre BeLauncher con ⇧⌘Espacio.** Aparece una caja en el centro. Escribe cualquier cosa.

Si no sabes qué escribir, prueba estas cinco, en este orden. En dos minutos entiendes el producto:

| Escribe | Y mira qué pasa |
| --- | --- |
| `2+2*10` | Calcula mientras escribes. Enter copia el resultado. |
| `10 km to mi` | Convierte unidades, monedas y zonas horarias igual. |
| `f informe` | Busca archivos por nombre en todo tu Mac. |
| `enfoque` | Una intención: te **enseña el plan** antes de tocar nada. |
| `recordar que subimos el precio a 90` | Propone guardarlo en tu cerebro. Confirmas tú. |

Cinco teclas y ya no necesitas nada más para empezar:

| Tecla | Qué hace |
| --- | --- |
| **⇧⌘Espacio** | Abre BeLauncher. |
| **⌥C** | Tu historial del portapapeles. |
| **↩** | Hace lo obvio con lo seleccionado. |
| **⌘K** | Todo lo demás que puedes hacer con eso. |
| **Tab** | Completa lo que estás escribiendo. |

> Si te perdiste el recorrido inicial, ábrelo cuando quieras: icono de la barra de menús →
> **Guía rápida**.

**Cuando no sepas qué se puede escribir**, abre Ajustes → **Qué puedo escribir**. Está todo listado
y con filtro.

---

## 2. Buscar y abrir

Escribe parte del nombre. No hace falta que sea el principio ni que esté bien escrito: `nton`
encuentra Notion.

Encuentra **aplicaciones**, **archivos** (con `f ` delante), **marcadores del navegador**, **carpetas
comunes**, **tus Atajos de macOS**, **snippets**, **flujos** y **lo que copiaste**.

- **↩** abre.
- **⌘↩** muestra en el Finder en vez de abrir.
- **⌘K** abre todas las acciones posibles sobre lo seleccionado.

**La lista aprende.** Lo que abres a menudo sube. Y si algo no sube lo suficiente, ponle un alias:
⌘K sobre ello → *Asignar un alias*. A partir de ahí `nav` puede abrir Safari aunque no se parezcan
en nada.

---

## 3. El portapapeles

**⌥C** abre el historial. Sale como una fila de tarjetas, no como una lista de texto: una captura se
reconoce mirándola, no leyéndola.

- **Flechas izquierda y derecha** recorren las tarjetas. Arriba y abajo también funcionan.
- **⌃⌘0** a **⌃⌘9** cogen esa tarjeta directamente, sin mover la selección.
- **Clic derecho** sobre una tarjeta da las mismas acciones que ⌘K.
- Una imagen se puede **arrastrar directamente** desde la vista previa a otra app.

Guarda texto, imágenes, archivos y enlaces.

**Lo que nunca guarda:** lo que copias desde un gestor de contraseñas (macOS lo marca como
confidencial y se respeta) y cualquier cosa con forma de credencial — claves de API, tokens, claves
privadas. Eso se descarta **antes** de escribirse en disco.

En Ajustes → Portapapeles puedes cambiar cuántos días guarda, cuántos elementos, y **excluir apps
por nombre** para que nada copiado desde ahí se registre.

---

## 4. Snippets: texto que se escribe solo

Un snippet es un texto con una palabra clave. Escribes la palabra en BeLauncher y te lo copia listo.

Se crean en Ajustes → **Mis atajos** → Snippets.

Dentro del texto puedes usar fichas que se rellenan al vuelo:

| Ficha | Se convierte en |
| --- | --- |
| `{clipboard}` | Lo último que copiaste |
| `{date}` | La fecha de hoy |
| `{time}` | La hora |
| `{uuid}` | Un identificador único |
| `{cursor}` | Dónde queda el cursor al pegar |
| `{secret:NOMBRE}` | Un secreto de tu Llavero |

Los **secretos** se guardan en el Llavero de macOS, nunca en la base de datos y **nunca en una
exportación**. Se gestionan en la misma pantalla.

---

## 5. Flujos: varias cosas de un tirón

Un flujo encadena pasos bajo una palabra. Se arman **sin escribir código**, en Ajustes →
**Mis atajos** → Flujos.

Pasos disponibles: abrir una app, abrir una URL, abrir un archivo, copiar un texto, pegar un
snippet, **ejecutar un comando del sistema**, ejecutar un Atajo de macOS, poner un temporizador y
esperar unos segundos.

Ejemplo, el de la web:

```
Flujo «enfoque»
1. Silenciar notificaciones
2. Abrir Notion y Terminal
3. Temporizador de 50 minutos
```

**Un flujo se detiene en el primer paso que falla.** Si silenciar no funciona, no sigue: terminar
con el temporizador puesto y las notificaciones encendidas es peor que no haber empezado.

> BeLauncher **no ejecuta scripts** que le des. Un flujo solo usa pasos que la app ya sabe hacer.
> Eso es lo que hace seguro instalar el flujo de otra persona.

---

## 6. Calcular y convertir

Escribe la operación y ya. `2+2`, `(15+3)*2`, `15% of 300`, `1200/12`.

Convierte unidades (`10 km to mi`), monedas y zonas horarias con la misma sintaxis.

**↩** copia el resultado en crudo, sin formato ni símbolos.

---

## 7. Comandos del sistema y ventanas

Escribe lo que quieres: `bloquear`, `dormir`, `papelera`, `modo oscuro`, `descargas`, `escritorio`.
La lista completa está en Ajustes → **Qué puedo escribir**.

**Todo lo irreversible pregunta antes**: cerrar sesión, reiniciar, apagar, vaciar la papelera y
expulsar discos. Lo demás se ejecuta directo.

**Ventanas**: mitad izquierda, mitad derecha, pantalla completa, centrar, mover al otro monitor.
Necesita el permiso de **Accesibilidad**.

> Estos comandos necesitan el permiso de **Automatización**. Si no lo tienes, no fallan en silencio:
> te lo dicen.

---

## 8. Inteligencia: elegir quién responde

Ajustes → **Inteligencia**.

**Modelos en tu Mac.** Si tienes Ollama o LM Studio corriendo, BeLauncher **los detecta y te enseña
qué modelos tienes** para que elijas. Es gratis, es privado y es la opción por defecto. Los modelos
de *embeddings* (nomic-embed-text, bge…) se filtran solos: no saben conversar.

Si no tienes ninguno: instala Ollama desde ollama.com y ejecuta `ollama pull qwen2.5`.

**Modelos en la nube.** Pones **tu clave** de OpenAI, Anthropic o Google. La clave va a tu Llavero y
las peticiones salen **de tu Mac directas al proveedor**: no pasan por Believe y le pagas a quien tú
elijas. La clave nunca se incluye en una exportación.

**«Lo confidencial nunca sale del Mac».** Con esto activado (viene activado), todo lo marcado como
material de empresa solo va a un modelo local. Si no hay ninguno, **se niega** en vez de mandarlo
igual.

**Probar.** El botón le pide una palabra al modelo elegido. Es la única forma de saber que una clave
funciona.

> Un modelo local tarda más **la primera vez**, mientras se carga en memoria. Las siguientes van
> rápidas. Si se alarga demasiado, hay botón de cancelar.

---

## 9. Pedirle cosas escribiendo

No hace falta seleccionar nada ni recordar atajos. Escribe el verbo:

| Escribe | Sobre qué |
| --- | --- |
| `traducir` | Lo último que copiaste |
| `traducir <texto>` | Ese texto |
| `resume`, `corrige`, `acorta`, `explica` | Igual |
| `tareas` | Saca las tareas de lo copiado |
| `json`, `tabla`, `puntos` | Formatea |
| `responder` | Redacta una respuesta |

También están todos con **⌘K** sobre cualquier resultado, si prefieres esa ruta.

---

## 10. Leer la pantalla

**⌥⇧Espacio** con cualquier cosa delante.

BeLauncher reconoce qué es y ofrece **tres cosas**, nunca un menú largo:

| Lo que ve | Te ofrece |
| --- | --- |
| Un error | Explícamelo · Cómo se arregla · Búscalo en la web |
| Una factura | Saca importe, fecha y proveedor · Archívala · Guárdalo en el cerebro |
| Un correo | Redacta la respuesta · Saca lo que me piden · Resume |
| Una tabla | Busca lo que se sale de la norma · Explícame qué dice · Pásala a Markdown |
| Código | Explícame qué hace · Dime qué está mal · Saca las tareas |
| Un diseño | Saca las tareas · Descríbeme lo que se ve · Extrae los textos |
| Un enlace | Ábrelo · Investígalo · Guárdalo |
| Texto | Resume · Traduce · Saca las tareas |

**Cómo lo lee, por orden:** primero lo que tengas **seleccionado** (instantáneo, exacto, y usa el
permiso de Accesibilidad que probablemente ya diste). Si no hay selección, el **archivo abierto** en
la ventana de delante. Y solo si tampoco, hace una **foto de la pantalla**, la lee en tu Mac con el
reconocimiento de texto de Apple y la descarta.

**Ninguna imagen se guarda ni se sube a ningún sitio.** Nada se captura sin que pulses el atajo.

---

## 11. Intenciones

Escribe **qué quieres conseguir**, no qué herramienta abrir:

- `enfoque` — silencia y arranca un bloque de trabajo
- `cerrar el día` — repasa lo pendiente y guarda lo aprendido
- `capturar reunión` — saca decisiones y compromisos de tus notas
- `ordena mis descargas`
- `convierte esto en una propuesta`
- `responde lo urgente`
- `publica esta idea`
- `limpia el escritorio`
- `arrancar la semana`

**Siempre te enseña el plan antes de hacer nada** que se note fuera de la app, y deja recibo de qué
cambió y qué se puede deshacer.

**Lo tuyo manda.** Si tienes un flujo, un atajo o un snippet llamado `enfoque`, `enfoque` es el
tuyo, punto. La app no compite con lo que tú construiste.

---

## 12. Encargos con «/»

Escribe `/` y sale la lista de encargos. Un encargo no es un atajo: es un agente con seis pasos
visibles.

1. **Mira** el contexto que tenga permitido (y solo ese)
2. **Pide** los permisos que le falten
3. **Planea**
4. **Te enseña** lo que va a hacer
5. **Ejecuta**
6. **Aprende** si te sirvió

Los que vienen de fábrica:

| Comando | Qué te da |
| --- | --- |
| `/prepare` | Quién viene, qué se decidió y qué está pendiente, antes de entrar |
| `/cierre` | Qué se cerró, qué quedó abierto y qué decidir mañana |
| `/followup` | El seguimiento con el tono correcto y sabiendo dónde quedó |
| `/acciones` | De unas notas en crudo, decisiones y compromisos |
| `/alta` | Ficha, accesos, entregables, carpeta y agenda de arranque |
| `/campana` | Audiencia, oferta, concepto, landing, anuncios, email y tareas |

El **`/`** es a propósito: sin él, buscar la palabra «prepare» lanzaría un agente.

---

## 13. Lienzos

Cuando lo que pides no es una respuesta sino varias piezas, se abre un lienzo: una ventana pequeña
con bloques.

Cada bloque **se rellena solo, de uno en uno**, para que puedas leer y editar el primero mientras
llegan los demás.

- **Lo que edites a mano nunca se sobrescribe.** Si vuelves a generar, se respeta lo tuyo.
- Cada bloque se copia o se regenera por separado.
- Los bloques de acción **solo se ejecutan** cuando pulsas *Ejecutar los pasos*.
- «Copiar todo» te lo lleva entero a donde quieras.

Se cierra y desaparece. No es un documento más que mantener.

---

## 14. Misiones que corren solas

Lo que tarda minutos no bloquea la ventana: va a la **bandeja de misiones**, que se abre sola al
encargar algo y también desde el menú.

Estados: preparando, falta un permiso, necesita que decidas, trabajando, terminado, falló,
cancelado. **El contador solo cuenta lo que espera algo de ti**, porque un contador que incluye lo
que ya trabaja solo enseña a ignorarlo.

Cada misión deja **seis cosas**, siempre, en *Ver qué hizo*:

1. El plan
2. De dónde sacó la información
3. Qué hizo exactamente
4. Cuánto costó (cero con modelo local)
5. Qué permisos usó
6. Qué se puede deshacer

Corren **dos como máximo a la vez**: más compiten por el mismo modelo y el mismo disco y hacen el
Mac peor de usar.

---

## 15. Tu cerebro

Lo que tu empresa **cree**: decisiones, políticas, compromisos, notas.

Vive en `~/Library/Application Support/BeLauncher/Vault`, en **archivos Markdown normales**. Al
crearse trae siete carpetas, una nota en cada una diciendo qué va dentro y un LÉEME que lo explica.

**Cómo se llena** (nunca a mano):

| Escribe | Qué hace |
| --- | --- |
| `recordar que …` | Propone guardarlo |
| `capturar reunión` | De tus notas, saca decisiones y compromisos |
| `qué decidimos sobre …` | Lo vigente hoy, no todo lo que se dijo |
| `prepárame para …` | Reúne lo que sabes de alguien |
| `pulse` | Qué se está pudriendo |

**Nada entra sin que lo confirmes.** Un cerebro que se escribe solo es un cerebro en el que no
puedes confiar.

**Verdad temporal.** Cada cosa sabe desde cuándo vale, a qué sustituyó y quién la decidió. Por eso
`qué decidimos sobre precios` responde lo de ahora y no un revuelto de tres años.

**`pulse`** es lo único que pregunta en vez de responder: contradicciones vigentes, compromisos
vencidos, decisiones sin respaldo, cosas sin dueño, decisiones caducadas sin reemplazo. Sobre un
cerebro vacío calla.

**Llevártelo:** en Ajustes → Mi cerebro hay dos botones. *Abrir en Obsidian* (la carpeta ya es un
almacén válido) y *Convertir en repositorio git* (hace `git init` con un `.gitignore` sensato; el
remoto y el push los decides tú).

---

## 16. Memoria de trabajo

Distinto del cerebro: esto es lo que **estabas haciendo**, no lo que la empresa cree.

Se activa en Ajustes → **Lo que observa**. Viene apagado.

Guarda personas, empresas, proyectos, archivos, reuniones, decisiones y compromisos, **y cómo se
conectan**. Guarda **nombres y fechas, nunca el contenido** de un archivo, un mensaje o una página.

Con eso puedes preguntar:

- `qué prometimos a Andrés` — incluye los compromisos que **salieron de una reunión suya** aunque no
  le nombren. Eso es lo que un grafo puede y una búsqueda por etiquetas no.
- `abre lo último de Project Atlas`
- `retoma lo que estaba haciendo antes de la llamada` — usa la hora real de la reunión
- `quién es Acme`

En Ajustes ves cuántas cosas de cada tipo tiene y hay un botón para borrarla entera.

---

## 17. Rutinas detectadas solas

Se activa en Ajustes → **Lo que observa**. Viene apagado.

Anota **qué tipo de cosa** haces y cuándo — abrir tal app, ejecutar tal comando — **nunca su
contenido**. Cuando la misma secuencia de tres pasos se repite **cuatro veces**, te ofrece
convertirla en un comando.

- Cuatro y no tres: tres es coincidencia lo bastante a menudo como para molestar.
- **Si dices que no, no se vuelve a preguntar por esa.**
- Lo que crea es un flujo normal, que puedes leer, editar y borrar.
- El historial se borra solo a los 14 días, y hay botón para borrarlo ya.
- Las 12 últimas anotaciones se ven en Ajustes, en cristiano.

---

## 18. Que aprenda cómo trabajas

Se activa en Ajustes → **Lo que observa**. Viene apagado.

Aprende de lo que **aceptas** y de lo que **reescribes**: si acortas los borradores, si saludas o vas
al grano, si eres formal o cercano, cómo nombras los archivos.

- **Nada cambia lo que produce hasta que cuatro observaciones coinciden.** Una preferencia a medias
  dirigiendo tu trabajo es peor que ninguna.
- **Se guarda la conclusión, nunca el texto** del que salió. Guarda «escribe corto», no tu correo.
- Cada cosa aprendida se ve en Ajustes, en una frase que reconoces, y se borra una por una o entera.
- Si cambias de forma de trabajar, se adapta: lo contradicho pierde confianza y acaba cambiando.

---

## 19. Equipo

Ajustes → **Encargos** → *Exportar / Importar comandos*, y Ajustes → **Mi cerebro** → *Compartir*.

**Memoria compartida.** Solo salen las memorias marcadas como `shared`, cifradas con una frase que
solo tiene tu equipo. Believe **nunca ve la clave ni el contenido**. Lo que llega llega como
propuesta: nada se aplica solo.

**Comandos compartidos.** Los encargos viajan **con las reglas de la casa dentro**: el tono, los
formatos, las carpetas, quién aprueba. Sin eso, compartir un comando es compartir solo un nombre, y
el `/propuesta` de cada uno produciría la idea que tiene el modelo de una propuesta en vez de la
vuestra.

**Lo tuyo siempre gana.** Si ya tienes un comando con ese nombre, el que llega se omite y se te dice
cuántos. Dos cosas respondiendo a `/propuesta` significa que la mitad de las veces corre la
equivocada y nadie puede saberlo.

---

## 20. Conectarlo a Claude o ChatGPT

BeLauncher habla **MCP**. El asistente que ya pagas puede consultar tu cerebro sin abrir el
lanzador.

Ajustes → **Mi cerebro** → *Copiar la configuración*, y la pegas en el archivo de Claude Desktop.

Cuatro herramientas: qué decidimos, preparar, buscar y proponer. **Solo lectura y propuesta**: un
asistente puede sugerir qué cree la empresa, nunca decidirlo.

---

## 21. Permisos, uno por uno

Todos se ven y se cambian en la **Guía rápida** (menú de la barra) y en Ajustes. Cada uno dice qué
te da, a qué accede y qué sigues teniendo si lo dejas apagado.

| Permiso | Para qué | Sin él |
| --- | --- | --- |
| **Historial del portapapeles** | ⌥C | Todo lo demás sigue igual |
| **Accesibilidad** | Pegar en la app anterior, colocar ventanas, leer la selección | Copias con Enter y pegas tú |
| **Automatización** | Comandos del sistema y pasos de flujo | Fallan con aviso, no en silencio |
| **Leer la pantalla** | ⌥⇧Espacio sobre cualquier cosa | Funciona con selección y portapapeles |
| **Calendario** | Preparar reuniones, «antes de la llamada» | Escribes tú con quién es |
| **Notificaciones** | Que avisen los temporizadores | Los flujos funcionan, no avisan |
| **Abrir al iniciar sesión** | El atajo funciona desde que enciendes | Lo abres a mano |
| **Buscar actualizaciones** | Aviso y botón de instalar | Nunca toca la red |

Los tres del sistema (Accesibilidad, Automatización, Pantalla) y el Calendario **los concede macOS**,
no la app: el interruptor se queda apagado hasta que macOS los conceda de verdad.

---

## 22. Privacidad: qué sale y qué no

**No hay cuenta, ni analítica, ni telemetría, ni servidor donde vivan tus datos.**

Lo que escribes, lo que copias, tu cerebro, tu memoria de trabajo y lo que aprende sobre ti se
quedan en este Mac.

**Solo salen tres cosas a la red, y las tres las decides tú:**

1. **La activación de la licencia**, una vez.
2. **Buscar si hay versión nueva**, si lo activaste. Es una petición para leer un número de versión:
   no lleva quién eres, ni qué usas, ni nada de tu Mac.
3. **Las peticiones de IA**, si eliges un modelo en la nube. Van de tu Mac directas al proveedor con
   tu clave.

Con un modelo local (Ollama, LM Studio), **ni eso**.

Lo que **nunca** se guarda ni se envía: contraseñas y credenciales copiadas, imágenes de pantalla, el
contenido de tus archivos, el texto del que aprendió tu estilo.

---

## 23. Tus datos

| Qué | Dónde |
| --- | --- |
| Ajustes, portapapeles, historial, memoria de trabajo, lo aprendido | `~/Library/Application Support/BeLauncher/belauncher.sqlite3` |
| Tu cerebro | `~/Library/Application Support/BeLauncher/Vault` (Markdown) |
| Secretos y claves de IA | Llavero de macOS |

En Ajustes → **Datos y privacidad**:

- **Exportar** (con o sin portapapeles) e **importar**
- **Diagnóstico** para cuando algo va mal
- **Importar de Alfred** y **de Raycast**: trae tus snippets y enlaces. Nunca sobrescribe: si ya
  tienes esa palabra clave, la tuya gana y te dice cuántas se omitieron.

---

## 24. Licencia y equipos

Licencia de por vida, hasta **3 equipos**. Se activa una vez con tu correo y tu clave
`BELN-XXXX-XXXX-XXXX`.

- **No revalida en cada arranque.** Si un día no hay red, la app funciona igual.
- Para liberar un Mac: Ajustes → General → *Desactivar en este equipo*.
- La licencia queda ligada a **ese** Mac: copiar la base de datos a otro no lleva la licencia con
  ella.

---

## 25. Actualizaciones

Con «Buscar actualizaciones» activado, la barra de menús muestra una línea — «Actualizar a X…» —
cuando hay versión nueva, y nada cuando no. Sin diálogos ni globos mientras trabajas.

El botón la instala solo: descarga, **comprueba que está firmada por Believe y notarizada por
Apple**, la reemplaza y te deja reiniciar cuando quieras.

**Se niega a instalar** cualquier cosa que no haya probado que viene de nosotros. Si algo falla, lo
dice y te deja bajarla a mano.

> Si vienes de la 0.16.0, esa versión salió con el updater roto: usa «Descargar a mano» una vez.

---

## 26. Cuando algo no funciona

**Un comando del sistema o un flujo no hace nada.** Falta el permiso de **Automatización**. Ajustes
del sistema → Privacidad y seguridad → Automatización.

**La IA tarda muchísimo o falla.** Comprueba en Ajustes → Inteligencia qué modelo tienes elegido. Si
usas Ollama, tiene que estar **abierto** y el modelo tiene que ser de chat.

**Dice que no hay ningún modelo.** O Ollama no está corriendo, o solo tienes modelos de embeddings,
o no has puesto ninguna clave.

**El lanzador no se lee bien sobre una ventana blanca.** No debería: el panel va fijado a apariencia
oscura. Si te pasa, mándanos el diagnóstico.

**Sale un aviso de permisos al arrancar.** No debería. Si uno de macOS se queda sin responder,
bloquea la ventana **aunque cierres la app**: respóndelo y listo.

**Algo que arreglamos te sigue fallando.** Mira la versión al final de Ajustes → General. Si no es la
última, es eso.

---

## 27. Todos los atajos

| Atajo | Qué hace |
| --- | --- |
| **⇧⌘Espacio** | Abrir BeLauncher (configurable) |
| **⌥C** | Historial del portapapeles |
| **⌥⇧Espacio** | Leer lo que hay en pantalla |
| **↩** | La acción principal |
| **⌘↩** | La secundaria (mostrar en Finder) |
| **⌘K** | Todas las acciones sobre lo seleccionado |
| **Tab** | Completar |
| **↑ ↓** | Moverse por la lista |
| **← →** | Moverse por las tarjetas del portapapeles |
| **⌃⌘0–9** | Coger esa tarjeta del portapapeles |
| **⌘,** | Ajustes |
| **Esc** | Cerrar, o volver un nivel |
| **/** | Ver los encargos |

---

## 28. Desinstalar del todo

1. Sal de BeLauncher desde la barra de menús.
2. Quita «Abrir al iniciar sesión» en Ajustes → General, o en Ajustes del sistema → Elementos de
   inicio.
3. Borra `BeLauncher.app` de Aplicaciones.
4. Borra `~/Library/Application Support/BeLauncher` (ahí están la base de datos y tu cerebro:
   **cópialos antes si los quieres**).
5. Los secretos y las claves de IA se borran en **Acceso a Llaveros**, buscando
   `com.believe.belauncher`.

No se escribe nada en ningún otro sitio.
