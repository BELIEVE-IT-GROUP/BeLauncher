# BeBrain — PRD de tres olas

**Producto:** BeLauncher para un usuario y su Mac. Nada de empresa, nada de equipos, nada de nube.
Lo colectivo llegará cuando esto haya aprendido, y hoy ya vive en otro sitio.

**La promesa:** *todo lo que pasa en tu Mac se vuelve preguntable.* Hoy esa frase es falsa, y este
documento es el plan para que deje de serlo.

---

## Dónde estamos de verdad (medido, 2026-08-05)

Tres comprobaciones, hechas sobre la app instalada y la base de datos real, no sobre supuestos:

| Qué se comprobó | Resultado |
|---|---|
| Motor de recuperación (pasajes, vectores, palabras, grafo) | **Funciona.** 58 clips → 152 pasajes → 152 vectores en 12,6 s |
| Servidor MCP: handshake y `tools/list` | **Funciona.** Protocolo correcto, 4 herramientas anunciadas |
| Servidor MCP: llamadas reales a esas herramientas | **Devuelve «no sé nada» siempre.** Leen solo el vault, que está vacío. No conocen el índice |
| Captura automática de lo que haces | **Apagada desde siempre.** `graph_enabled = false`. 0 nodos, 0 aristas |
| Modelo de embeddings en un Mac cualquiera | **No hay.** Funciona en el Mac de George porque tiene `bge-m3` instalado por otra razón |

La lectura honesta: **hay motor y no hay combustible, y lo poco que hay no está enchufado a la
única puerta por la que se va a usar.**

---

## OLA 1 — Que sirva desde fuera y desde el primer minuto

**Duele hoy:** el usuario conecta BeLauncher a Claude, ve «conectado», pregunta y no obtiene nada.
Y en un Mac recién instalado la búsqueda por significado no existe porque no hay modelo.

### 1.1 Enchufar MCP al cerebro real

Las cuatro herramientas actuales leen el vault de memorias confirmadas. Ese es el 2 % del material.
Tienen que leer el índice completo: memorias, portapapeles, grafo de trabajo y notas.

**Herramientas que quedan:**

| Herramienta | Qué hace | Por qué existe |
|---|---|---|
| `recall` | Búsqueda por significado sobre todo lo indexado, con citas | Es la que faltaba. La razón de ser de la ola |
| `context_for` | Reúne el contexto de una tarea: «voy a rehacer el documento X» → devuelve lo relevante, ordenado y citado | **El caso de George.** No pegar contexto a mano: que Claude se lo pida al cerebro |
| `what_was_i_doing` | Lo último trabajado, por tramos de tiempo | Retomar después de una interrupción |
| `propose_memory` | Propone guardar algo. Nunca escribe solo | Ya existe. Se mantiene el principio: nada entra sin que una persona diga que sí |

`what_did_we_decide` y `prepare` se reescriben sobre el índice o desaparecen. Hoy son promesas que
contestan «no sé nada».

**Criterio de aceptación:** desde Claude Desktop, sin tocar BeLauncher, una pregunta sobre algo que
el usuario copió la semana pasada devuelve el pasaje con su fecha y su origen.

### 1.2 «Conectado» tiene que significar algo

Hoy el botón dice conectado cuando ha escrito una línea en un archivo de configuración. Eso no es una
conexión, es una intención.

**Conectado pasa a significar:** se lanzó el binario, se completó el handshake, se listaron las
herramientas y **una llamada real devolvió datos**. Tres de esos cuatro pasos pueden fallar en
silencio y hoy fallan.

- Autoprueba en Ajustes que ejecuta esa secuencia y **enseña lo que volvió**, no un punto verde.
- Cuando falla, dice cuál de los cuatro pasos y qué hacer.
- `--diagnose-mcp` para pegar la salida cuando algo no cuadra, igual que `--diagnose-ai`.

**Criterio de aceptación:** con el índice vacío a propósito, la autoprueba **falla** y explica por
qué. Un verde que aparece pase lo que pase es peor que ningún indicador.

### 1.3 El modelo, con un clic y explicado

Un usuario nuevo abre la app y la función estrella no existe. No es aceptable, y no se arregla con
un enlace a una documentación.

- Al arrancar se detecta si hay Ollama y si hay modelo de embeddings.
- Si no: una pantalla que lo dice en una frase — *el cerebro necesita un modelo que entienda
  significados. Son 2 GB, se queda en tu Mac, no sale nada a internet* — y un botón.
- El botón instala Ollama si hace falta y descarga `bge-m3`, con progreso real y opción de
  cancelar.
- **Mientras baja, la app funciona:** busca por palabras y dice qué le falta. Nunca una app rota
  esperando una descarga.
- Quien lo rechaza puede seguir. El aviso reaparece una vez, no cada arranque.

**Por qué `bge-m3` y no otro:** medido sobre un corpus real de 12 frases y 4 preguntas. `bge-m3`
acertó 4 de 4; `nomic-embed-text` 2 de 4; los embeddings nativos de macOS entre 0 y 1 de 4. El
ranking del código refleja esa medición y se revisa cuando alguien mida otra cosa.

### Lo que la ola 1 NO trae

Ninguna fuente de captura nueva. Meter navegador y audio antes de que el material existente sea
consultable es llenar más rápido un almacén que nadie sabe abrir.

---

## OLA 2 — El corpus: episodios, identidades, relevancia, destilado

**Duele hoy:** aunque encendiéramos toda la captura, el resultado sería un vertedero. El motor
recupera bien si le dan buen material, y hoy nadie decide qué es buen material.

Esta ola es **el producto**. Las otras dos son el envase.

### 2.1 Episodios, no eventos

Nadie pregunta «qué hice a las 14:32». Preguntan **«cómo resolví lo de autenticación»**.

Dos horas saltando entre tres archivos, cuatro pestañas y una conversación con Claude son **un**
recuerdo, no cuarenta filas. Un episodio tiene: un tramo de tiempo, un asunto, lo que se tocó
dentro y cómo acabó.

- Fronteras por inactividad y por cambio de asunto, no por reloj.
- Un episodio se titula solo, con el modelo local, a partir de lo que contiene.
- Es la unidad que se indexa y se cita. Los eventos sueltos siguen guardados, pero no se buscan.

**Cómo se mide:** un conjunto de preguntas con respuesta conocida, escrito antes de construir.
Sin eso, «mejores relaciones» es una opinión. Con eso, es un número que sube o baja.

### 2.2 Identidades

El mismo proyecto aparece como una ruta de carpeta, un título de pestaña, un nombre de archivo y
una frase en un chat. **Si eso son cuatro nodos, el grafo es decorativo.**

- Entidades canónicas con alias. Una entidad reúne sus formas, no las duplica.
- Se unen por evidencia — coincidencia de ruta, de dominio, de nombre propio, de aparecer juntas
  una y otra vez — no por parecido de letras.
- **Nunca se unen dos entidades en silencio.** Se propone y se ve. Una fusión equivocada
  contamina cada respuesta futura y es invisible desde fuera.

Es la parte más difícil de las cuatro y donde casi todos los productos de memoria son flojos.

### 2.3 Relevancia

La mayoría de lo que pasa es ruido. Si todo pesa igual, la búsqueda se ahoga en pestañas abiertas
tres segundos.

Señales baratas y honestas, sin leer contenido: tiempo dentro, si volviste otro día, si copiaste
algo de ahí, si aparece junto a cosas que ya importan. Lo que no llega al umbral se guarda pero no
se indexa. **Un cerebro que recuerda todo por igual no recuerda nada.**

### 2.4 Destilado

Un cerebro que guarda lo que pasó **recupera**. Uno que resume sus episodios en frases
**responde**.

Una pasada nocturna del modelo local sobre los episodios del día produce afirmaciones cortas
—*esta semana peleaste con auth en X, lo cerraste así*— cada una con su cita al episodio del que
salió. Local, barata, y es la diferencia entre buscar y recordar.

### 2.5 Fuentes nuevas, ahora que hay criterio

En este orden:

1. **Conversaciones con IA.** Claude Code deja las sesiones en el disco en JSONL. Es indexable
   directamente, sin capturar pantalla ni pedir permisos nuevos. Máximo valor, mínimo coste.
2. **Navegador.** El historial de Safari y Chrome son bases SQLite locales. Contesta la pregunta
   «dónde vi ese artículo», que hoy es imposible.
3. **Audio y reuniones.** macOS trae transcripción en el dispositivo. **Se cablea lo que ya está,
   no se monta un servicio.** Antes de prometerlo se verifica en un Mac real, igual que se hizo
   con los embeddings — esa comprobación fue lo que evitó construir sobre un motor que no servía.
4. **Código.** Fuera. Tu código ya está en git, que es mejor historial que cualquier captura.

### 2.6 Privacidad: requisito, no adorno

**Nada de lo anterior se enciende sin esto.** Capturar más sin controles es una promesa que no se
puede sostener.

- Pausar la captura, y que se note que está pausada.
- Excluir apps y sitios concretos, con una lista que el usuario ve y edita.
- Borrar un periodo: *olvida el martes por la tarde*, y que desaparezca del índice, del grafo y
  del disco.
- Todo local. Sale a la red solo si el usuario configura un modelo en la nube, y entonces se dice
  en cada llamada.

### Lo que la ola 2 NO trae

Nada visual. El corpus se construye antes de dibujarlo.

---

## OLA 3 — Verlo: el corpus en la mano

**Duele hoy:** el cerebro es una caja negra. El usuario no puede mirar lo que sabe de él, ni
corregirlo, ni llevárselo. Y un cerebro que no se puede auditar no se puede confiar.

### 3.1 El corpus es Markdown, y eso no se negocia

Ya lo es para las memorias y tiene que serlo para todo: episodios, entidades y afirmaciones
destiladas, en archivos `.md` con enlaces `[[así]]` en una carpeta que el usuario elige.

La consecuencia buena es inmediata: **esa carpeta abierta con Obsidian ya es un grafo visual, sin
que nosotros escribamos una línea de vista.** Y significa que irse de BeLauncher no cuesta nada,
que es la única forma honesta de pedirle a alguien que ponga aquí su memoria.

### 3.2 Grafo nativo, para quien no usa Obsidian

Una vista propia dentro del launcher, no un sustituto de Obsidian: entidades y episodios como
nodos, las relaciones como aristas, filtrable por tiempo y por tipo.

Sirve para tres cosas concretas, y si no sirve para las tres no vale la pena:
- **Ver qué sabe de ti**, que es lo que convierte una caja negra en una herramienta.
- **Corregirlo**: unir dos entidades que son la misma, separar dos que no lo son, borrar lo que
  sobra. Las correcciones vuelven al motor.
- **Navegar**: pinchar un nodo y llegar a lo que hay debajo.

### 3.3 Los `.md` desde el launcher

Buscar un episodio, verlo entero, abrirlo en Obsidian o en el editor de siempre, editarlo a mano.
Lo que se edite a mano **manda sobre lo que dedujo la máquina** y no se sobrescribe nunca.

### Decisión abierta de esta ola

Si el grafo nativo se construye entero o si Obsidian cubre el 80 % y solo hacemos una vista mínima
de corrección. Se decide **al final de la ola 2**, cuando se sepa cuántos nodos y aristas produce
un mes de uso real. Decidirlo antes es diseñar para un tamaño imaginado.

---

## Principios que valen para las tres olas

1. **Medir antes de construir.** Los embeddings nativos de Apple parecían la opción obvia y
   acertaban 1 de 4. Se descubrió midiendo, en veinte minutos, antes de construir encima.
2. **La búsqueda semántica falla en silencio.** Siempre devuelve algo, así que un motor malo pasa
   por bueno hasta que alguien mira los resultados. Cada ola deja un diagnóstico que se puede
   ejecutar y pegar.
3. **Verificar por el camino de la persona.** «Conectado» se comprueba llamando a la herramienta
   desde fuera, no leyendo un archivo de configuración.
4. **Nada entra en la memoria en silencio.** Se propone, una persona confirma. Y lo que huele a
   credencial no entra ni al índice.
5. **Todo local por defecto.** Sin cuentas, sin telemetría, sin plano de control.
6. **El usuario se puede ir.** Markdown en su carpeta, siempre.
