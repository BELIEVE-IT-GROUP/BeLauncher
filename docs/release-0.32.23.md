# BeLauncher 0.32.23: voz real y dictado insertable

## Qué se corrigió

Qwen podía mezclar el progreso de Hugging Face con la salida de voz. Una línea como
`Fetching 11 files: 100%|...|` podía terminar como transcripción. Dictate tampoco tenía un
destino explícito cuando se iniciaba desde el panel del launcher.

Ahora la app separa `stdout` de Qwen de sus diagnósticos, desactiva barras de progreso, rechaza una
respuesta vacía, conserva la app activa antes de abrir el launcher, solicita Accesibilidad antes de
empezar Dictate, reactiva la app destino y envía `Cmd-V` con el texto transcrito. La transcripción
también se guarda en Brain junto con el origen del audio.

## Evidencia ejecutada

- `swift test --disable-sandbox`: **1045 tests en 144 suites, todos pasan**.
- Qwen local: import de `qwen3_asr_mlx` correcto.
- Prueba de audio real generada con `say`, normalizada a WAV y ejecutada por Qwen 0.6B: obtuvo
  texto transcrito en 2.436 segundos, no una barra de progreso.

La inserción en una aplicación externa requiere una prueba manual con Accesibilidad concedida.

## Prueba manual de aceptación

1. Abre TextEdit y deja el cursor en un documento nuevo.
2. Inicia `Dictate into the current app` o el atajo de dictado.
3. Habla cinco segundos y detén la captura.
4. Comprueba que TextEdit recibe tus palabras, no `Fetching`, porcentajes ni mensajes de Python.
5. Abre Brain y verifica la nota con la transcripción y el origen `.m4a`.
6. Repite con el launcher abierto para verificar que el destino sigue siendo TextEdit.
