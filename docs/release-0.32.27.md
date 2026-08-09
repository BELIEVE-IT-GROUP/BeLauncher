# BeLauncher 0.32.27: Inbox humano y Markdown íntegro

Esta release implementa dos puntos del plan de acción: hacer visible y accionable el recorrido del
Inbox desde el Overview, y garantizar que la edición de Markdown no destruya contenido válido del
cuerpo.

## Inbox y notas

- El Inbox del Overview tiene acciones explícitas para actualizarlo y abrir todas las notas.
- Cuando no hay elementos pendientes, ofrece crear una nota directamente; no deja una pantalla
  vacía sin siguiente paso.
- La superficie `My notes` puede refrescarse sin cerrar ni reabrir la ventana.
- Se mantiene el flujo de lectura, edición, guardado, revisión, transcripción y apertura de la
  fuente original.
- Las acciones nuevas tienen traducción en el catálogo español; el test de localización las cubre.

## Markdown sin pérdida

- El parser del Inbox reconoce únicamente el cierre de front matter al inicio del archivo.
- Un separador horizontal `---` dentro del cuerpo ya no se confunde con el cierre YAML.
- `body(from:)`, `markReviewed` y `updateBody` usan la misma separación estructural.
- Revisar o editar una nota conserva front matter, procedencia, estado de revisión y todo el
  cuerpo posterior al separador.

## Verificación

- QuickNote: **9 tests en 1 suite, todos pasan**.
- Suite completa compilada y ejecutada: **1051 tests en 144 suites**; el único fallo observado fue
  el benchmark existente de 15.000 bookmarks, que midió 51,18 ms contra un umbral estricto de
  50 ms bajo carga concurrente.
- El benchmark aislado `SearchPerformanceTests` pasa; no se relajó su umbral.
- `git diff --check` pasa.

## Límite explícito

Este corte mejora el recorrido humano de notas e Inbox. No declara terminados los conectores
externos planificados ni la detección automática de Zoom, Meet o Teams.
