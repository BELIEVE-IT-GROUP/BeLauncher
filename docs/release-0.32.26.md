# BeLauncher 0.32.26: fuentes verificables y Brain navegable

Esta release implementa dos puntos del plan de acción: hacer que las fuentes locales profundas
solo se presenten como conectadas cuando la evidencia sigue siendo legible, y llevar las
invocaciones de notas directamente a la superficie humana de Markdown del Brain.

## Fuentes profundas sin falsos positivos

- Mail, Messages y Notes siguen requiriendo Full Disk Access y una sincronización completada.
- La comprobación posterior a la sincronización valida ahora que el recurso local siga siendo
  legible, no solo que el archivo exista.
- Si una base local desaparece o deja de poder leerse, el estado vuelve a `Available` y el centro
  de fuentes conserva el estado accionable de la última lectura.
- La comprobación acepta una ruta de `home` inyectada en pruebas, sin leer bases reales del equipo.

## Brain y notas

- `my notes`, `notes` y `quick note` activan la ruta de notas del launcher de forma explícita.
- App Intent `Open Notes` abre el Brain directamente en `My notes`, en vez de dejar al usuario con
  una búsqueda ambigua en el launcher.
- App Intent `Review Voice Notes` abre la misma superficie para que las notas pendientes de voz
  sean visibles y accionables.
- Se conserva la navegación existente: lista de Markdown, lectura, edición, guardado, revisión,
  transcripción y apertura del archivo original en Finder.

## Verificación

- Pruebas dirigidas: **9 tests en 2 suites, todos pasan**.
- Suite completa: ejecutada; todos los cambios funcionales pasan. El primer intento tuvo una
  única fluctuación del benchmark existente de 15.000 bookmarks (53,6 ms frente a un umbral de
  50 ms); la suite aislada pasó en la repetición siguiente. El umbral no se relajó.
- No se alteraron los conectores externos planificados ni se declaró conectada ninguna fuente sin
  evidencia local verificable.

## Límite explícito

Esta release no implementa aún la selección automática de Zoom, Meet o Teams, ni convierte el
Brain en un duplicado de todas las bases del Mac. Esas capas siguen separadas del conector local
de Mail, Messages, Notes y navegadores ya existente.
