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
