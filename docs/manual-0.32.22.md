# BeLauncher 0.32.22: corrección de voz y guía

Esta release contiene todo lo descrito en [manual-0.32.21.md](manual-0.32.21.md) y añade una
corrección crítica de transcripción Qwen.

## Corrección incluida

Qwen/Hugging Face podía escribir una barra de descarga como:

```text
Fetching 11 files: 100%|...| 11/11 [...]
```

El proceso compartía esa salida con el texto transcrito y la app podía guardarla como una nota de
voz o pegarla en la aplicación activa. Desde `0.32.22`:

- las barras de progreso se desactivan por entorno (`HF_HUB_DISABLE_PROGRESS_BARS`, `TQDM_DISABLE`);
- las líneas de progreso se filtran antes de crear la transcripción;
- si solo queda progreso y no hay texto, la transcripción falla con estado vacío;
- una línea de transcripción real se conserva;
- existe una prueba automática específica contra este caso.

## Prueba rápida de voz

1. Instala `0.32.22` sin borrar el corpus.
2. Pulsa el atajo de nota de voz.
3. Habla una frase de cinco segundos.
4. Detén la grabación y espera la revisión.
5. El resultado debe contener tus palabras, no `Fetching`, porcentajes ni una barra de descarga.
6. Repite con Dictate y comprueba que el texto llega a la aplicación activa.

Si vuelve a fallar, guarda el error completo, el proveedor seleccionado, el modelo y la versión.
No borres el audio temporal ni reinstales Qwen antes de reportarlo.
