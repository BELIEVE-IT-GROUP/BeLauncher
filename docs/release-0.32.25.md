# BeLauncher 0.32.25: Shortcuts estables y App Intents curados

Esta release implementa dos puntos del plan de acción: la primera capa de Shortcuts estable y la
superficie curada de App Intents.

## Shortcuts estable

- `BELShortcutMapping` conserva el ID estable de la acción, el nombre humano, versión y estado.
- Los mappings se guardan en `UserDefaults` y se resuelven por ID, no por texto localizado.
- Los nombres de fallback deben comenzar por `BEL • ` y no pueden contener saltos de línea ni NUL.
- Un mapping duplicado, inválido o desactivado no entra en ejecución.
- Un fallback comprueba que `/usr/bin/shortcuts` exista, que el nombre esté presente en
  `shortcuts list`, ejecuta con argumentos separados y conserva stdout/stderr separados.
- Un exit code distinto de cero se devuelve como error tipado con stderr acotado; nunca se informa
  éxito.
- La confirmación R2 sigue centralizada en `BELActionExecutor`.

## App Intents

La aplicación publica 16 comandos conectados a acciones existentes:

1. Abrir Brain
2. Mostrar portapapeles
3. Abrir ajustes
4. Grabar nota de voz
5. Dictar en la app actual
6. Leer pantalla
7. Escribir nota rápida
8. Grabar llamada
9. Buscar en Brain
10. Próximas reuniones
11. Iniciar focus
12. Preparar reunión
13. Abrir notas
14. Abrir grafo
15. Revisar notas de voz
16. Abrir launcher

Las acciones que requieren UI declaran `openAppWhenRun` y llegan al app mediante notificaciones
tipadas. Las acciones no ejecutan una promesa falsa en background: abren la superficie que permite
revisar o confirmar la operación.

## Verificación

- Suite completa: **1048 tests en 144 suites, todos pasan**.
- Contrato y mapping BEL: 7 pruebas relevantes.
- Bridge de App Intents y adapters nativos: 7 pruebas relevantes.
- Suite de localización, permisos, catálogo y errores completa.

## Límite explícito

Esto no convierte automáticamente las 156 acciones conceptuales del spec en acciones nativas. Las
acciones sin adapter siguen declaradas como `unavailable` o `shortcutFallback`; no aparecen como
implementadas por el mero hecho de estar catalogadas.
