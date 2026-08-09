# BeLauncher 0.32.21: manual de prueba

Esta es la guía práctica de lo que puedes probar después de instalar la release. Las pruebas están
ordenadas de menor a mayor dependencia del sistema. En todas: pulsa el atajo del launcher, escribe
la frase exacta y pulsa Return. Si una frase no aparece, no la consideres una función disponible:
reporta la frase, el resultado visible y la versión.

## Preparación

1. Instala `BeLauncher-0.32.21.dmg` encima de la instalación anterior.
2. No borres `~/Library/Application Support/BeLauncher`; ahí están el corpus, clips, notas y ajustes.
3. Abre Settings y confirma `0.32.21`.
4. En cada prueba anota si apareció permiso, si apareció un resultado y qué hizo Return.
5. Para una prueba limpia de permisos usa solo el panel de BeLauncher para iniciar el flujo; no
   marques una prueba como correcta porque macOS ya tenía el permiso concedido.

## Las 15 pruebas nuevas

### 1. Abrir el Brain desde el launcher

Escribe `cerebro` o `open brain`. Debe aparecer una acción de Brain. Return abre la ventana del
grafo/Brain sin abrir una segunda ventana vacía.

### 2. Abrir el Brain con App Intent

En Shortcuts crea o ejecuta `Open Brain` de BeLauncher. Debe traer la ventana Brain al frente. Si
BeLauncher estaba cerrado, registra si macOS lo lanzó y si la ventana apareció.

### 3. Mostrar el portapapeles con App Intent

Ejecuta `Show Clipboard` en Shortcuts. Debe abrir el launcher directamente en el carrusel de
portapapeles, conservando la barra de comandos.

### 4. Abrir Settings con App Intent

Ejecuta `Open BeLauncher Settings` en Shortcuts. Debe mostrar Settings sin buscar manualmente el
icono de la bandeja.

### 5. Abrir un archivo por ruta

Escribe `open file ~/Desktop/prueba.md`. Debe aparecer el archivo y Return debe abrirlo con su app
predeterminada. Sustituye la ruta por un archivo real.

### 6. Revelar un archivo en Finder

Escribe `reveal file ~/Desktop/prueba.md` o `show file ~/Desktop/prueba.md`. Command-Return debe
revelarlo en Finder. Comprueba que el nombre mostrado es el real, no `url.lastPathComponent`.

### 7. Mover un archivo a la papelera

Escribe `trash file ~/Desktop/prueba.md`. Debe pedir confirmación antes de actuar. Cancelar no debe
mover nada; confirmar debe moverlo a la papelera y mostrar un resultado de acción.

### 8. Ejecutar un Shortcut existente

Escribe `run shortcut Nombre exacto`. Debe pedir confirmación. Al confirmar, ejecuta
`/usr/bin/shortcuts` sin shell. Un nombre inexistente debe mostrar el error real y no un falso éxito.

### 9. Leer el contexto actual sin OCR

Selecciona texto en Notes, Safari o un editor y escribe `read screen`. Debe devolver el texto
seleccionado o, si no hay selección, el contexto barato disponible. No debe pedir Screen Recording
solo por leer una selección.

### 10. Ejecutar OCR explícito de pantalla

Escribe `ocr screen`. En el primer uso debe pedir Screen Recording. Tras aprobarlo, debe devolver
texto reconocido de una sola captura local. Si cancelas el permiso, debe explicar el bloqueo y no
decir que la acción terminó.

### 11. Extraer texto de un PDF

Escribe `read pdf /ruta/al/documento.pdf`. Return debe extraer texto localmente con PDFKit. El PDF
no se copia automáticamente al Brain: el resultado solo se muestra para que decidas qué guardar.

### 12. Buscar próximas reuniones

Escribe `upcoming meetings` o `next meetings`. La primera vez debe pedir Calendar si no está
concedido. Después debe mostrar eventos próximos no marcados como todo el día.

### 13. Preparar una reunión con el Brain

Escribe `prepare me for my next meeting` o `prepárame para mi próxima reunión`. Debe combinar el
evento de Calendar con la memoria local y explicar si falta una fuente. No debe inventar contexto
cuando Calendar está vacío.

### 14. Probar una acción sin permiso

Revoca temporalmente Screen Recording o Calendar en System Settings y repite la acción. Debe quedar
bloqueada con un motivo específico. Este caso prueba el gate central, no solo el mensaje de UI.

### 15. Confirmar que el catálogo es bilingüe y estable

Con el idioma español escribe `read screen`, `leer pantalla`, `read pdf` y `leer PDF`. Debe aparecer
la misma acción estable aunque cambie el texto visible. Cambiar el idioma no debe crear duplicados ni
ejecutar otra acción.

## Pruebas del Brain y del launcher ya disponibles

Estas no son nuevas APIs, pero forman parte de la experiencia que debe probarse en la release:

- Vacía la consulta y verifica que aparece el carrusel de clips.
- Usa el carrusel completo con rueda/trackpad y confirma que los clips antiguos siguen accesibles.
- Escribe `nota` o usa `Write a quick note`; debe abrir el editor, guardar Markdown y mostrarlo en
  `My notes`.
- Abre un Markdown desde Brain, edítalo y vuelve a abrirlo; debe conservar el contenido.
- Escribe `recordar que el cliente aprobó X`; debe crear una propuesta, no una memoria confirmada.
- Confirma la propuesta y verifica que aparece en el Brain con su fuente.
- Usa `pulse`; debe mostrar señales o explicar que no hay nada que señalar.
- Abre un nodo del grafo y usa `Read here`; el contenido debe aparecer dentro del Brain, no en una
  ventana vacía separada.
- Graba una nota de voz corta, espera la revisión y comprueba que la transcripción no se guarda como
  verdad comprometida sin confirmación.
- Ejecuta `--benchmark-startup` en el binario firmado y registra `launcher-ready-ms` con el corpus
  real; no uses solo la sensación de rapidez.

## Proveedores y voz

Para cada proveedor configurado, Settings debe mostrar una respuesta verificable:

1. Prueba OpenAI con una clave válida y registra modelo, latencia y respuesta.
2. Prueba Ollama con el servicio ejecutándose y registra el nombre exacto del modelo.
3. Si Qwen está instalado, graba audio y registra la etapa de preparación, modelo y error exacto.
4. Si Qwen falla, conserva el mensaje completo y el código de salida; “conectado” no cuenta como
   resultado.
5. Verifica que Apple Speech queda como fallback cuando el proveedor local no puede leer el audio.

## Cómo reportar un fallo útil

Incluye siempre:

- versión visible en Settings;
- Mac y versión de macOS;
- frase exacta escrita o atajo usado;
- resultado que apareció en el launcher;
- permiso mostrado en System Settings;
- proveedor/modelo elegido;
- texto exacto del error;
- si el corpus anterior seguía en su carpeta;
- `launcher-ready-ms` si el problema es lentitud.

No borres el corpus ni reinstales desde cero antes de reportar: eso elimina la evidencia necesaria
para distinguir un fallo de migración, permiso, proveedor o rendimiento.
