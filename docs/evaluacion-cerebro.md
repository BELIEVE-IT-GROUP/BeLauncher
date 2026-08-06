# Cómo se mide si el cerebro mejora

Sin esto, «mejores relaciones» y «recupera mejor» son opiniones, y cada cambio en el corpus se
defiende con una anécdota. Con esto, es un número que sube o baja.

Se escribe **antes** de construir la ola 2, a propósito: un conjunto de evaluación escrito después
de ver los resultados se acaba pareciendo a los resultados.

---

## Cómo funciona

Un archivo de casos. Cada caso es una pregunta, lo que tiene que aparecer en la respuesta y lo que
no debe aparecer. El corredor hace la pregunta al cerebro real y comprueba tres cosas:

- **Acierto en el primer puesto.** ¿El pasaje correcto es el número uno?
- **Acierto entre los tres primeros.** Porque una respuesta con tres opciones y la buena dentro
  sigue siendo útil.
- **Silencio correcto.** Cuando la respuesta no está en el corpus, ¿lo dice, o rellena con lo
  menos irrelevante que tiene?

Ese tercero importa tanto como los otros dos y casi nadie lo mide. Un cerebro que siempre contesta
algo es un cerebro en el que no se puede confiar, porque no hay forma de distinguir cuándo sabe de
cuándo improvisa.

---

## Las siete familias de pregunta

Cada una ataca una capacidad distinta. Si una familia baja, se sabe exactamente qué se rompió.

### 1. Paráfrasis pura
*«cuánto cobramos por el Pro»* cuando el corpus dice *«el precio base es 1000 euros»*.
**Mide:** que el motor de significado funciona. Ninguna palabra en común.

### 2. Literal exacto
*«factura 2024-0871»*, *«García»*, un código de producto.
**Mide:** que la mitad por palabras no se perdió al añadir los vectores. Es el fallo clásico de
quien monta búsqueda semántica y rompe la búsqueda normal sin darse cuenta.

### 3. Relación de un salto
*«qué prometimos a Andrés»* cuando el compromiso salió de una reunión suya y **no le nombra**.
**Mide:** el grafo. Ningún parecido de texto encuentra esto, porque el texto no contiene la
respuesta. Solo una arista.

### 4. Identidad
La misma pregunta formulada con las cuatro caras del mismo proyecto: la ruta de la carpeta, el
título de la pestaña, el nombre del archivo y como se dice en voz alta.
**Mide:** la resolución de identidades. Las cuatro tienen que dar la misma respuesta. Si dan
cuatro respuestas distintas, el grafo es decorativo.

### 5. Tiempo
*«cómo resolví lo de autenticación hace dos meses»*, *«qué estuve haciendo el martes»*.
**Mide:** los episodios. Un evento suelto no contesta esto; un tramo con asunto, sí.

### 6. Relevancia
Una pregunta cuya respuesta buena está enterrada bajo veinte pestañas abiertas tres segundos
sobre el mismo asunto.
**Mide:** el filtro de ruido. Sin él, la respuesta correcta sale en el puesto veintiuno.

### 7. Vacío honesto
Una pregunta sobre algo que **no ocurrió**.
**Mide:** que el cerebro sabe callarse. La respuesta correcta es decir que no consta.

---

## Reglas del conjunto

- **Casos reales, del uso real.** Un conjunto inventado mide un cerebro inventado.
- **Un caso por comportamiento**, no veinte variantes de lo mismo: infla el número sin medir más.
- **Los negativos pesan igual que los positivos.** Al menos un caso de vacío honesto por familia.
- **Se congela una versión por ola.** Comparar contra un conjunto que cambia no compara nada.
- **Cuando algo falla en el uso real, se añade como caso** antes de arreglarlo. Así la regresión
  no vuelve.
- **Nunca se afina el corpus para aprobar el examen.** Si un caso empieza a pasar por una regla
  escrita para ese caso, el caso deja de medir.

---

## Cuándo se corre

En cada cambio del corpus, del troceado, del modelo de embeddings o de la fusión. Son las cuatro
cosas que pueden mejorar una familia y romper otra a la vez, en silencio, sin que ninguna prueba
unitaria se entere.

El resultado se guarda con la fecha y el modelo usado. Cambiar de modelo de embeddings sin volver
a medir es empezar de cero creyendo que se sigue igual.
