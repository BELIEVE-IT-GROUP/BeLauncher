# BeLauncher 0.32.24: diagnóstico real del audio

Qwen ya no devuelve únicamente `Qwen ASR returned no text` cuando el archivo no contiene señal
audible. Antes de invocar el modelo, BeLauncher inspecciona la grabación normalizada y comprueba
duración, pico y RMS. Así distingue entre:

- una grabación demasiado corta;
- una grabación silenciosa o sin entrada de micrófono;
- una respuesta vacía del modelo pese a que sí había señal.

La causa concreta queda incluida en la evidencia pendiente de transcripción. El cambio no duplica
el audio ni lo envía fuera del Mac.

## Verificación

- Tests dirigidos de transcripción: 30 tests en 3 suites, todos pasan.
- El test nuevo crea un WAV silencioso de un segundo y verifica pico/RMS cero.
- La prueba de audio con voz sintética de la release anterior sigue funcionando con Qwen 0.6B.

En el archivo reportado desde `/Users/georgeslaptop` no se puede medir la señal desde este runner,
porque esa ruta pertenece al otro Mac. En `0.32.24`, la propia app mostrará si la próxima captura
llega vacía o silenciosa, en lugar de ocultarlo como un fallo genérico de proveedores.
