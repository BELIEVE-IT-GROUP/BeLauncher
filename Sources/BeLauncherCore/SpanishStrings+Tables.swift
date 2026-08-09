import Foundation

// The Spanish side of the catalog.
//
// Not a literal translation of the English, and it should not become one. The Spanish text came
// first and was written sentence by sentence; where a literal rendering of the newer English would
// have flattened it, the original phrasing was kept. Both sides are meant to read as if that
// language were the only one the product had.

extension SpanishStrings {

    // MARK: - The brain: recall, decisions, preparation

    static let brain: [String: String] = [
        "Nothing matches those words, and without an embedding model there is no search by meaning.":
            "No hay nada con esas palabras. Sin modelo de embeddings no puedo buscar por significado.",
        "The brain knows nothing about this yet.":
            "El cerebro no tiene nada sobre esto todavía.",
        "Words only. Searching by meaning needs an embedding model.":
            "Solo por palabras: falta un modelo de embeddings para buscar por significado.",
        "There is no decision in force about “%@” any more":
            "Ya no hay una decisión vigente sobre «%@»",
        "The last one was “%1$@” and it was superseded on %2$@. Nobody recorded what replaced it.":
            "La última fue «%1$@» y quedó sustituida el %2$@. Nadie registró la que la reemplazó.",
        "The decision in force is missing.":
            "Falta registrar la decisión vigente.",
        "Nothing has been decided about “%@”":
            "No hay ninguna decisión registrada sobre «%@»",
        "When you decide, save it with “remember” and it will sit here with its date, its owner and what it replaced.":
            "Cuando la toméis, guardadla con «recordar» y quedará aquí con su fecha, su dueño y lo que sustituye.",
        "The brain knows nothing about this subject yet.":
            "El cerebro no sabe nada de este tema todavía.",
        "Decided by %@":
            "Decidido por %@",
        "in force since %@":
            "vigente desde el %@",
        "source: %@":
            "fuente: %@",
        "Open evidence in the Brain":
            "Abrir evidencia dentro del Brain",
        "This source has no local document yet":
            "Esta fuente todavía no tiene un documento local",
        "Running": "En ejecución",
        "Completed": "Completada",
        "Failed": "Falló",
        "Cancelled": "Cancelada",
        "Interrupted": "Interrumpida",
        "Recent missions": "Misiones recientes",
        "Open mission details": "Abrir detalles de la misión",
        "Steps": "Pasos",
        "Receipt": "Recibo",
        "This run has not produced a receipt yet.": "Esta ejecución todavía no tiene recibo.",
        "Review and approve again": "Revisar y aprobar de nuevo",
        "Close": "Cerrar",
        "Replaced:":
            "Sustituyó a:",
        "Also in force on this:":
            "También vigente sobre esto:",
        "Decision in force":
            "Decisión vigente",
        "I know nothing about “%@” yet":
            "Todavía no sé nada de «%@»",
        "When there are decisions, commitments or notes about this, they will be gathered here before the meeting.":
            "Cuando haya decisiones, compromisos o notas sobre esto, aparecerán aquí reunidas antes de la reunión.",
        "No material on this subject.":
            "Sin material sobre este asunto.",
        "With: %@":
            "Con: %@",
        "Decisions in force:":
            "Decisiones vigentes:",
        "Open commitments:":
            "Compromisos abiertos:",
        "Learnings:":
            "Aprendizajes:",
        "Notes:":
            "Notas:",
        "%@ commitment(s) on this are still open.":
            "Hay %@ compromiso(s) sin cerrar sobre esto.",
        "Preparation: %@":
            "Preparación: %@",
        "What we know about %@":
            "Lo que sabemos de %@",
        "Nothing outstanding with %@":
            "No hay nada pendiente con %@",
        "%1$@ commitment(s) with %2$@":
            "%1$@ compromiso(s) con %2$@",
        "No open commitments, and nothing that came out of a meeting of theirs.":
            "Ni compromisos abiertos ni nada salido de una reunión suya.",
        "Nothing recent about %@":
            "Nada reciente sobre %@",
        "The latest on %@":
            "Lo último de %@",
        "due %@":
            "para %@",
        "overdue":
            "vencido",
        "1 source":
            "1 fuente",
        "%@ sources":
            "%@ fuentes",
    ]

    // MARK: - Setup: the model, the connection, the first run

    static let setup: [String: String] = [
        "Nothing is indexed yet.":
            "Todavía no hay nada indexado.",
        "One fragment of your notes, your work and your clipboard.":
            "Un fragmento de tus notas, tu trabajo y tu portapapeles.",
        "%@ fragments of your notes, your work and your clipboard.":
            "%@ fragmentos de tus notas, tu trabajo y tu portapapeles.",
        "The moment you save something or copy a piece of text, it shows up here.":
            "En cuanto guardes algo o copies un texto, aparece aquí.",
        "They are searched by exact words. None of them understands meaning yet: the model is missing.":
            "Se buscan por palabras exactas. Ninguno entiende significado todavía: falta el modelo.",
        "All of them understand meaning.":
            "Todos entienden significado.",
        "None of them understands meaning yet. Start processing and this number climbs.":
            "Ninguno entiende significado todavía. Empieza a procesarlos y esta cifra sube.",
        "%1$@ understand meaning. %2$@ still to process.":
            "%1$@ entienden significado. Faltan %2$@ por procesar.",
        "Model %@, running on your Mac. Nothing goes to the internet.":
            "Modelo %@, corriendo en tu Mac. No sale nada a internet.",
        "Model %@, on a server. The text you search leaves your Mac to reach it.":
            "Modelo %@, en un servidor. El texto que buscas sale de tu Mac para llegar hasta él.",
        "No model installed.":
            "Sin modelo instalado.",
        "Rebuild the index":
            "Rehacer el índice",
        "Cuts everything again and reprocesses it from scratch. It takes a while, it deletes no notes, and it is only worth doing if the results stop making sense.":
            "Vuelve a cortar todo y a procesarlo desde cero. Tarda, no borra ninguna nota y solo hace falta si los resultados dejan de tener sentido.",
        "Rebuilding the index…":
            "Rehaciendo el índice…",
        "Index rebuilt: %1$@ fragments, %2$@ of them with meaning.":
            "Índice rehecho: %1$@ fragmentos, %2$@ con significado.",
        "Let it understand what you mean":
            "Que entienda lo que quieres decir",
        "Right now it finds things by the words you type. With this model it also finds them by what they mean: you ask “what do we charge for Pro” and up comes “the base price is 1000 EUR”, without a single word in common.":
            "Ahora mismo encuentra por las palabras que escribes. Con este modelo encuentra también por lo que significan: preguntas «cuánto cobramos por el Pro» y aparece «el precio base es 1000 EUR», aunque no compartan ni una palabra.",
        "Carry on without it":
            "Seguir sin él",
        "You can add it later from Settings, under “My brain”.":
            "Puedes ponerlo más tarde desde Ajustes, en «Mi cerebro».",
        "Keep using BeLauncher while it downloads. We will tell you here when it is done.":
            "Sigue usando BeLauncher mientras se descarga. Cuando termine te lo decimos aquí.",
        "Done. It searches by meaning now.":
            "Listo. Ya busca por significado.",
        "Download Ollama":
            "Descargar Ollama",
        "Install with Homebrew":
            "Instalar con Homebrew",
        "The model comes down through Ollama, which is free and also stays on your Mac. Pick how to install it: nothing runs until you press something.":
            "El modelo se descarga a través de Ollama, que es gratis y también se queda en tu Mac. Elige cómo instalarlo: nada se ejecuta sin que lo pulses.",

        // Getting the model onto the machine
        "The brain needs a model that understands meaning: about 2 GB, it stays on your Mac, and nothing goes to the internet.":
            "El cerebro necesita un modelo que entienda significados: son unos 2 GB, se queda en tu Mac y no sale nada a internet.",
        "Without this model, BeLauncher still searches by exact words and by relations: it is not broken, it just does not understand synonyms yet.":
            "Sin este modelo, BeLauncher sigue buscando por palabras exactas y por relaciones: no está roto, solo no entiende sinónimos todavía.",
        "Install Ollama": "Instalar Ollama",
        "Get Ollama running": "Poner Ollama en marcha",
        "Download %@ (~2 GB)": "Descargar %@ (~2 GB)",
        "Ollama did not start. Open it from Applications and try again.":
            "Ollama no arrancó. Ábrelo desde Aplicaciones y vuelve a intentarlo.",
        "Ollama did not start. In a terminal: “brew services start ollama”, then try again here.":
            "Ollama no arrancó. En una terminal: «brew services start ollama», y vuelve a intentarlo aquí.",
        "Ollama did not start. In a terminal: “%@ serve”, then try again here.":
            "Ollama no arrancó. En una terminal: «%@ serve», y vuelve a intentarlo aquí.",
        "Ollama is not on this Mac yet. Install it first.":
            "Ollama todavía no está en este Mac. Instálalo primero.",
        "Nobody has looked yet at whether the model is on this Mac.":
            "Todavía no se ha mirado si el modelo está en este Mac.",
        "Checking whether the meaning model is installed…":
            "Comprobando si el modelo de significado está instalado…",
        "Ready. Search by meaning is using %@.":
            "Listo. La búsqueda por significado usa %@.",
        "To switch on search by meaning, what is missing: %@.":
            "Para activar la búsqueda por significado falta: %@.",
        "Installing Ollama…": "Instalando Ollama…",
        "Getting Ollama running…": "Poniendo Ollama en marcha…",
        "Download cancelled. Nothing was installed and you can pick it up whenever you like: what came down already is kept.":
            "Descarga cancelada. No se instaló nada y puedes retomarla cuando quieras: lo que ya se había bajado se conserva.",
        "The model's %1$@ will not fit: only %2$@ is free on the disk.":
            "No caben los %1$@ del modelo: solo quedan %2$@ libres en el disco.",
        "Getting the download ready…": "Preparando la descarga…",
        "Downloading… %@%%": "Descargando… %@%%",
        "Verifying what came down…": "Verificando lo descargado…",
        "Done.": "Listo.",
        "Downloading…": "Descargando…",
        "%1$@ (%2$@ of %3$@)": "%1$@ (%2$@ de %3$@)",
        "There is not enough room on the disk to finish the download.":
            "No hay espacio suficiente en el disco para terminar la descarga.",
        "No internet connection. Check the network and try again.":
            "No hay conexión a internet. Revisa la red e inténtalo de nuevo.",
        "Ollama is not answering. Start it and try again.":
            "Ollama no responde. Ponlo en marcha y vuelve a intentarlo.",
        "Ollama answered, but it cannot find the model “%@”. Update Ollama: older versions do not know this one.":
            "Ollama respondió, pero no encuentra el modelo «%@». Actualiza Ollama: las versiones viejas no conocen este modelo.",
        "The download failed: %@": "La descarga falló: %@",
        "Ollama answered %@.": "Ollama respondió %@.",

        // The five-step connection check
        "answers with data":
            "responde con datos",
        "All five steps pass: a real call brings content back.":
            "Los cinco pasos pasan: una llamada real trae contenido.",
        "unchecked":
            "sin comprobar",
        "The connection has not been tested yet.":
            "Todavía no se ha probado la conexión.",
        "Press “%@” and the five steps run.":
            "Pulsa «%@» y se ejecutan los cinco pasos.",
        "not set up":
            "sin configurar",
        "will not start":
            "no arranca",
        "no reply":
            "no contesta",
        "no tools":
            "sin herramientas",
        "comes back empty":
            "responde vacío",
        "Press “Connect” next to it. The entry is added to that app's configuration without touching anything already in there.":
            "Pulsa «Conectar» aquí al lado. Se añade la entrada a la configuración de esa app sin tocar lo que ya tuviera.",
        "The path saved in that assistant no longer leads to BeLauncher, usually because the app moved folder. Press “Connect” again to write the current one.":
            "La ruta guardada en ese asistente ya no lleva a BeLauncher, normalmente porque la app se movió de carpeta. Pulsa «Conectar» otra vez para escribir la ruta actual.",
        "The process starts but does not answer. Quit the assistant, open it again and check once more. If it stays like this, reinstall BeLauncher.":
            "El proceso arranca pero no responde. Cierra el asistente, ábrelo de nuevo y vuelve a comprobar. Si sigue igual, reinstala BeLauncher.",
        "This version starts but announces no tools. Update BeLauncher from Settings › General.":
            "Esta versión arranca pero no anuncia ninguna herramienta. Actualiza BeLauncher desde Ajustes › General.",
        "The plumbing works and the content does not arrive. Rebuild the index under “Brain status” and check again; if it is still empty, send the diagnostic.":
            "La tubería funciona y el contenido no llega. Rehaz el índice en «Estado del cerebro» y vuelve a comprobar; si sigue vacío, manda el diagnóstico.",
        "Nobody has checked this connection yet.":
            "Nadie ha comprobado esta conexión todavía.",
        "Press “%@”: it starts BeLauncher the way your assistant would and asks it a real question.":
            "Pulsa «%@»: arranca BeLauncher como lo haría tu asistente y hace una pregunta real.",
        "everything answers":
            "todo responde",
        "One assistant is getting real data.":
            "Un asistente recibe datos de verdad.",
        "%@ assistants are getting real data.":
            "%@ asistentes reciben datos de verdad.",
        "%@ with no data":
            "%@ sin datos",
        "Nothing reaches: %@.":
            "No llega nada a: %@.",
        "Open each one to see which step it breaks at.":
            "Abre cada uno para ver en qué paso se corta.",
        "Wrote %1$@'s configuration. That is the only thing we can claim so far: restart %1$@ and press “%2$@” to see whether data actually reaches it.":
            "Escrita la configuración de %1$@. Eso es lo único que se puede afirmar por ahora: reinicia %1$@ y pulsa «%2$@» para ver si de verdad le llegan datos.",
        "%1$@ already had the BeLauncher entry. A file mentioning it is no proof that anything arrives: press “%2$@” to find out.":
            "%1$@ ya tenía la entrada de BeLauncher. Que el archivo la mencione no prueba que reciba nada: pulsa «%2$@» para comprobarlo.",
        "Really check it":
            "Comprobar de verdad",
        "Checking…":
            "Comprobando…",
        "It starts BeLauncher exactly as your assistant would, asks it a question whose answer we know, and checks that content comes back. A configuration file mentioning us is not enough.":
            "Arranca BeLauncher igual que lo haría tu asistente, le hace una pregunta cuya respuesta conocemos y comprueba que vuelva con contenido. No basta con que el archivo de configuración nos mencione.",
    ]

    // MARK: - Privacy: pausing, excluding, forgetting

    static let privacy: [String: String] = [
        "Pause": "Pausar",
        "While it is paused nothing is saved: not what you open, not what you copy, not who you talk to. Everything from before stays where it was.":
            "Mientras está en pausa no se guarda nada: ni lo que abres, ni lo que copias, ni con quién hablas. Lo de antes sigue donde estaba.",
        "15 minutes": "15 minutos",
        "1 hour": "1 hora",
        "Until tomorrow": "Hasta mañana",
        "Until I turn it back on": "Hasta que lo reanude yo",
        "It is capturing.": "Está capturando.",
        "It saves what you open and what you copy so it can answer you later. All of it stays on this Mac.":
            "Guarda lo que abres y lo que copias para poder responderte después. Todo se queda en este Mac.",
        "Paused: you are sharing your screen.": "En pausa: estás compartiendo pantalla.",
        "It comes back on its own when you stop sharing. What is on screen during a demo usually belongs to someone else.":
            "Se reanuda solo cuando dejes de compartir. Lo que hay en la pantalla durante una demo suele ser de otra persona.",
        "Back on its own in %@.": "Vuelve solo en %@.",
        "Back on its own in a while.": "Vuelve solo dentro de un rato.",
        "Paused. Nothing is being saved.": "En pausa. No se guarda nada.",
        "Resume now": "Reanudar ahora",
        "It stays like this until you turn it back on.": "Sigue así hasta que lo reanudes tú.",
        "Resume": "Reanudar",
        "Paused": "En pausa",
        "less than a minute": "menos de un minuto",
        "1 minute": "1 minuto",
        "%@ minutes": "%@ minutos",
        "%@ hours": "%@ horas",
        "%1$@ and %2$@": "%1$@ y %2$@",
        "<1 min": "<1 min",
        "%@ min": "%@ min",
        "%@ h": "%@ h",
        "%1$@ h %2$@ min": "%1$@ h %2$@ min",
        "Resuming brings nothing back from the pause. It was never saved; it is nowhere.":
            "Reanudar no recupera nada de lo que pasó durante la pausa. No se guardó, no está en ningún sitio.",
        "What it never looks at": "Lo que nunca mira",
        "Not the name, not the content. If an app or a site is on this list, as far as BeLauncher is concerned it does not exist.":
            "Ni el nombre ni el contenido. Si una app o una web está en esta lista, para BeLauncher es como si no existiera.",
        "These come set from the factory. You can remove them, but they are there because your password manager and your bank are not things anybody wants remembered.":
            "Estas vienen puestas de fábrica. Puedes quitarlas, pero están ahí porque tu gestor de contraseñas y la web de tu banco no son cosas que nadie quiera recordar.",
        "No app is excluded. Everything you open counts.":
            "No hay ninguna app excluida. Todo lo que abras cuenta.",
        "No domain is excluded. Every site you visit counts.":
            "No hay ningún dominio excluido. Toda la web que veas cuenta.",
        "App name or its identifier": "Nombre de la app o su identificador",
        "yourbank.com": "tubanco.com",
        "Keychain Access": "Acceso a Llaveros",
        "Apple Passwords": "Contraseñas de Apple",
        "A domain has no spaces in it. Write something like “%@”.":
            "Un dominio no lleva espacios. Escribe algo como «%@».",
        "That does not look like a domain. Write something like “%@”.":
            "Eso no parece un dominio. Escribe algo como «%@».",
        "Write the app's name as it appears in the Dock, or its identifier.":
            "Escribe el nombre de la app tal como aparece en el Dock, o su identificador.",
        "The factory ones are still on the list: adding your own does not remove them.":
            "Las de fábrica siguen en la lista: añadir una tuya no las quita.",
        "Forget a stretch of time": "Olvidar un rato",
        "It really deletes what was saved in that period. No trash, no undo, no copy: it is the one thing in this app that cannot be recovered.":
            "Borra de verdad lo que se guardó en ese periodo. No hay papelera, no hay deshacer y no hay copia: es lo único de esta app que no se puede recuperar.",
        "The last hour": "La última hora",
        "Today": "Hoy",
        "This afternoon": "Esta tarde",
        "A specific stretch": "Un rato concreto",
        "1 fragment": "1 fragmento",
        "%@ fragments": "%@ fragmentos",
        "1 clipboard copy": "1 copia del portapapeles",
        "%@ clipboard copies": "%@ copias del portapapeles",
        "1 thing you were working on": "1 cosa de lo que estabas haciendo",
        "%@ things you were working on": "%@ cosas de lo que estabas haciendo",
        "Nothing was saved in that stretch.": "En ese rato no se guardó nada.",
        "Deleted for good: %@.": "Se borra para siempre: %@.",
        "Deleted for good: %1$@ and %2$@.": "Se borra para siempre: %1$@ y %2$@.",
        "Nothing is saved under “%@”.": "No hay nada guardado en «%@».",
        "There is nothing to delete, so there is nothing to confirm.":
            "No hay nada que borrar, así que no hay nada que confirmar.",
        "Got it": "Entendido",
        "Forget “%@”?": "¿Olvidar «%@»?",
        "This cannot be undone.": "No se puede deshacer.",
        "Forget 1 thing": "Olvidar 1 cosa",
        "Forget %@ things": "Olvidar %@ cosas",
        "Cancel": "Cancelar",
        "Nothing was saved under “%@”.": "No había nada guardado en «%@».",
        "Forgotten: 1 thing from “%@”. It is nowhere now.":
            "Olvidado: 1 cosa de «%@». Ya no está en ningún sitio.",
        "Forgotten: %1$@ things from “%2$@”. They are nowhere now.":
            "Olvidado: %1$@ cosas de «%2$@». Ya no están en ningún sitio.",
        "Part of it went, but 1 thing is still there. Quit BeLauncher, open it again and repeat: it is almost always something that was mid-write.":
            "Se borró parte, pero 1 cosa sigue ahí. Cierra BeLauncher, ábrelo otra vez y repite: casi siempre es que algo estaba escribiendo en ese momento.",
        "Part of it went, but %@ things are still there. Quit BeLauncher, open it again and repeat: it is almost always something that was mid-write.":
            "Se borró parte, pero %@ cosas siguen ahí. Cierra BeLauncher, ábrelo otra vez y repite: casi siempre es que algo estaba escribiendo en ese momento.",
        "Counting what is in that stretch…": "Contando lo que hay en ese rato…",
        "From": "Desde",
        "To": "Hasta",
        "The start date comes before the end date.": "La fecha de inicio va antes que la de fin.",
        "fragment": "fragmento",
        "fragments": "fragmentos",
        "Pieces of your notes and your work, searchable one by one.":
            "Trozos de tus notas y tu trabajo, buscables uno a uno.",
        "understand what you mean": "entienden lo que quieres decir",
        "The rest are only found by their exact words.":
            "Los demás solo se encuentran por las palabras exactas.",
        "stretch of work": "rato de trabajo",
        "stretches of work": "ratos de trabajo",
        "Grouped sessions: what you did in one go, uninterrupted.":
            "Sesiones agrupadas: lo que hiciste seguido, sin cortes.",
        "name it knows": "nombre conocido",
        "names it knows": "nombres conocidos",
        "People, companies and projects it can recognise.":
            "Personas, empresas y proyectos que sabe reconocer.",
        "saved copy": "copia guardada",
        "saved copies": "copias guardadas",
        "What you copied and is still in the history.":
            "Lo que copiaste y sigue en el historial.",
        "There is nothing in it yet.": "Todavía no tiene nada dentro.",
        "The moment you save a note or copy a piece of text, it shows up here and can be counted. Not one number on this screen is an estimate.":
            "En cuanto guardes una nota o copies un texto, aparece aquí y se puede contar. Ninguna cifra de esta pantalla es una estimación.",
        "Counting what is stored…": "Contando lo que hay guardado…",
        "The brain's status could not be read: %@. Press “Refresh”; if it stays like this, export the diagnostic from Data and send it to us.":
            "No se pudo leer el estado del cerebro: %@. Pulsa «Actualizar»; si sigue igual, exporta el diagnóstico desde Datos y mándanoslo.",
        "Refresh Inbox": "Actualizar Inbox",
        "Open all notes": "Abrir todas las notas",
        "Write a note": "Escribir una nota",
        "Refresh notes": "Actualizar notas",
        "All of this is worked out and kept on this Mac.":
            "Todo esto se calcula y se guarda en este Mac.",
        "The model that understands meaning lives on a server: the text you search leaves this Mac to reach it. Install a local one if you would rather nothing left.":
            "El modelo que entiende significado está en un servidor: el texto que buscas sale de este Mac para llegar hasta él. Instala uno local si prefieres que no salga nada.",
    ]

    // MARK: - Onboarding: what it needs, why, and what it does with it

    static let onboarding: [String: String] = [
        "Clipboard history": "Historial del portapapeles",
        "Get back anything you copied, with ⌥C. Text, images and files.":
            "Recuperas cualquier cosa que copiaste, con ⌥C. Textos, imágenes y archivos.",
        "What you copy, stored on your Mac. Never what you copy out of a password manager, and never anything shaped like a key or a token: that is thrown away before it is written.":
            "Lo que copias, guardado en tu Mac. Nunca lo que copias desde un gestor de contraseñas, ni nada con forma de clave o token: eso se descarta antes de escribirse.",
        "The launcher, the snippets and everything else carry on. You only lose the history.":
            "El lanzador, los snippets y todo lo demás siguen igual. Solo pierdes el historial.",
        "Accessibility": "Accesibilidad",
        "Pasting straight into the app you were in, and moving windows around (left half, full screen, across two displays).":
            "Pegar directamente en la app donde estabas, y colocar ventanas (mitad izquierda, pantalla completa, entre dos monitores).",
        "macOS only lets an app press ⌘V in another app, or move its window, with this permission. BeLauncher uses it for nothing else: it does not read your screen, your keystrokes, or the contents of other apps.":
            "macOS solo deja pulsar ⌘V en otra app o mover su ventana con este permiso. BeLauncher no lo usa para nada más: no lee tu pantalla, ni tus pulsaciones, ni el contenido de otras apps.",
        "You copy with Enter and paste yourself with ⌘V. Window management does not work.":
            "Copias con Enter y pegas tú con ⌘V. La gestión de ventanas no funciona.",
        "Automation": "Automatización",
        "System commands and flows: silence notifications, put the Mac to sleep, dark mode, empty the trash, eject disks, run your macOS Shortcuts. Without it, a flow like “focus” runs and nothing happens.":
            "Los comandos de sistema y los flujos: silenciar notificaciones, poner el Mac en reposo, modo oscuro, vaciar la papelera, expulsar discos, ejecutar tus Atajos de macOS. Sin esto, un flujo como «enfoque» se ejecuta y no pasa nada.",
        "macOS asks for this because it technically allows asking other apps for things. BeLauncher only asks “System Events” and the Finder, and only when you run a command. It does not read the contents of your apps or drive them on its own.":
            "macOS pide este permiso porque técnicamente permite pedirle cosas a otras apps. BeLauncher solo se lo pide a «System Events» y al Finder, y solo cuando tú ejecutas un comando. No lee el contenido de tus apps ni las controla por su cuenta.",
        "Everything else works. System commands and the flow steps that touch the Mac fail with a warning instead of failing quietly.":
            "Todo lo demás funciona. Los comandos de sistema y los pasos de flujo que tocan el Mac fallan con un aviso, en vez de en silencio.",
        "Read the screen": "Leer la pantalla",
        "Press ⌥⇧Space with anything in front of you — an error, an invoice, an email, a table — and it offers the three sensible things to do with it. No copying, no switching windows, no explaining where it came from.":
            "Pulsas ⌥⇧Espacio con cualquier cosa delante — un error, una factura, un correo, una tabla — y te ofrece las tres cosas sensatas que hacer con ello. Sin copiar, sin cambiar de ventana, sin explicar de dónde salió.",
        "Almost never the screen: it first tries to read whatever you have selected, which needs none of this. Only when there is no selection does it take a picture of the screen, read it **on your Mac** with Apple's text recognition, and throw it away. No image is stored and nothing is uploaded. What it recognises goes to the model you chose, exactly as if you had typed it. Nothing is captured unless you press the shortcut.":
            "Casi nunca la pantalla: primero intenta leer lo que tengas seleccionado, que no necesita esto. Solo si no hay selección hace una foto de la pantalla, la lee **en tu Mac** con el reconocimiento de texto de Apple y la descarta. No se guarda ninguna imagen, ni se sube a ningún sitio. Lo que se reconoce va al modelo que tú elegiste, igual que si lo hubieras escrito. Nada se captura sin que pulses el atajo.",
        "It still works with whatever you have selected and with the clipboard. You only lose the “I can see it but I cannot select it” case.":
            "Sigue funcionando con lo que tengas seleccionado y con el portapapeles. Solo pierdes el caso de «lo veo pero no puedo seleccionarlo».",
        "Calendar": "Calendario",
        "“Prepare me for the meeting with Acme” gathers what you know about them and crosses it with what is on your calendar today.":
            "«Prepárame para la reunión con Acme» reúne lo que sabes de ellos y lo cruza con lo que tienes agendado hoy.",
        "Only the titles and times of your events, read at that moment and never stored or sent anywhere.":
            "Solo los títulos y horas de tus eventos, leídos en el momento y nunca guardados ni enviados a ningún sitio.",
        "Preparing for a meeting still works, but you have to type who it is with.":
            "Preparar una reunión sigue funcionando, pero tienes que escribir tú con quién es.",
        "Notifications": "Notificaciones",
        "Flow timers tell you when they finish. Without this, a 50-minute focus block ends in silence.":
            "Los temporizadores de los flujos te avisan cuando terminan. Sin esto, un bloque de enfoque de 50 minutos acaba en silencio.",
        "Nothing. It only allows showing a notice.": "Nada. Solo permite mostrar un aviso.",
        "Flows work; timers do not announce themselves.":
            "Los flujos funcionan; los temporizadores no avisan.",
        "Open at login": "Abrir al iniciar sesión",
        "The global shortcut works from the moment you turn on the Mac, without opening anything.":
            "El atajo global funciona desde que enciendes el Mac, sin abrir nada.",
        "Nothing. It is a macOS setting.": "Nada. Es un ajuste de macOS.",
        "You will have to open BeLauncher by hand every day.":
            "Tendrás que abrir BeLauncher a mano cada día.",
        "Check for updates": "Buscar actualizaciones",
        "It tells you in the menu bar when there is a new version and installs it with one button.":
            "Te avisa en la barra de menús cuando hay versión nueva y la instala con un botón.",
        "One request to our download server to read a version number. It carries no idea who you are, what you use, or anything from your Mac.":
            "Una petición a nuestro servidor de descargas para leer un número de versión. No lleva quién eres, ni qué usas, ni nada de tu Mac.",
        "It never touches the network. You find out about new versions wherever you like.":
            "Nunca toca la red. Te enteras de las versiones nuevas por donde tú quieras.",

        "BeLauncher has no account, no analytics, no telemetry, and no server where your data lives.":
            "BeLauncher no tiene cuenta, ni analítica, ni telemetría, ni servidor donde vivan tus datos.",
        "What you type, what you copy and what you keep in your brain stay on this Mac, in one database and one folder of Markdown files you can open, copy or delete yourself.":
            "Lo que escribes, lo que copias y lo que guardas en tu cerebro se quedan en este Mac, en una base de datos y una carpeta de archivos Markdown que puedes abrir, copiar o borrar tú mismo.",
        "Only three things ever reach the network, and you decide all three: activating your licence (once), checking whether there is a new version, and AI requests if you pick a cloud model. Those go from your Mac straight to the provider with your key: they do not pass through us.":
            "Solo salen tres cosas a la red, y las tres las decides tú: la activación de la licencia (una vez), buscar si hay versión nueva, y las peticiones de IA si eliges un modelo en la nube. Esas van de tu Mac directas al proveedor con tu clave: no pasan por nosotros.",
        "With a local model (Ollama, LM Studio), not even that.":
            "Con un modelo local (Ollama, LM Studio) ni eso.",

        "Opens BeLauncher. Start typing to search apps, files and everything else.":
            "Abre BeLauncher. Escribe y empieza a buscar apps, archivos y todo lo demás.",
        "Your clipboard history.": "Tu historial del portapapeles.",
        "Does the obvious thing with whatever is selected: open the app, copy the result.":
            "Hace lo obvio con lo que tengas seleccionado: abrir la app, copiar el resultado.",
        "Everything else you can do with it: reveal in Finder, ask the AI for something, give it an alias.":
            "Todo lo demás que puedes hacer con eso: revelar en Finder, pedirle algo a la IA, ponerle un alias.",
        "Completes what you are typing.": "Completa lo que estás escribiendo.",
        "Works it out as you type. Enter copies the result.":
            "Calcula mientras escribes. Enter copia el resultado.",
        "Converts units, currencies and time zones the same way.":
            "Convierte unidades, monedas y zonas horarias igual.",
        "f report": "f informe",
        "Finds files by name across your whole Mac.":
            "Busca archivos por nombre en todo tu Mac.",
        "focus": "enfoque",
        "A mission: it silences everything and starts a 50-minute block. It shows you the plan before doing anything.":
            "Una misión: silencia, y arranca un bloque de 50 minutos. Te enseña el plan antes de hacer nada.",
        "remember we raised the price to 90": "recordar que subimos el precio a 90",
        "Offers to keep it in your brain. You confirm.":
            "Propone guardarlo en tu cerebro. Tú confirmas.",
    ]

    // MARK: - Settings

    static let settings: [String: String] = [
        "Language": "Idioma",
        "Only what the app says to you. What you have saved keeps whatever language it was written in, and search still works across both.":
            "Solo lo que la app te dice a ti. Lo que tienes guardado conserva el idioma en el que se escribió, y la búsqueda sigue cruzando los dos.",
        "Global shortcut": "Atajo global",
        "Clipboard": "Portapapeles",
        "Open BeLauncher at login": "Abrir BeLauncher al iniciar sesión",

        // The sections down the side of Settings
        "General": "General",
        "Intelligence": "Inteligencia",
        "What I can type": "Qué puedo escribir",
        "Errands": "Encargos",
        "What it watches": "Lo que observa",
        "Privacy": "Privacidad",
        "My shortcuts": "Mis atajos",
        "My brain": "Mi cerebro",
        "Data": "Datos",
        "Shortcut, startup, licence": "Atajo, arranque, licencia",
        "Which model answers, and with whose key": "Qué modelo responde y con qué clave",
        "What gets saved and what does not": "Qué se guarda y qué no",
        "Everything the window understands": "Todo lo que entiende la ventana",
        "“/” commands and missions in flight": "Comandos con «/» y misiones en marcha",
        "History, working memory and what it learned":
            "Historial, memoria de trabajo y lo aprendido",
        "Pause, exclude, forget": "Pausar, excluir, olvidar",
        "Snippets, flows, aliases, secrets": "Snippets, flujos, alias, secretos",
        "Where your notes live and who can read them":
            "Dónde viven tus notas y quién puede leerlas",
        "Export, import, uninstall": "Exportar, importar, desinstalar",

        // First run: the welcome, the licence, the launcher window itself
        "Back": "Atrás",
        "Get started": "Empezar",
        "Next": "Siguiente",
        "One key for everything you do on your Mac.":
            "Una tecla para todo lo que haces en el Mac.",
        "Press **⇧⌘Space** whenever you like and start typing. It opens apps and files, works out sums, converts things, keeps what you copy, fires off multi-step flows and answers questions about what your company already decided.":
            "Pulsa **⇧⌘Espacio** en cualquier momento y escribe. Abre apps y archivos, calcula, convierte, guarda lo que copias, dispara flujos de varios pasos y responde preguntas sobre lo que tu empresa ya decidió.",
        "Your data stays here": "Tus datos se quedan aquí",
        "What do you want it to be able to do": "Qué quieres que pueda hacer",
        "Switch on whatever is useful to you. You can change it any time in Settings, and under each one it says exactly what it reaches and what happens if you leave it off.":
            "Enciende lo que te sirva. Puedes cambiarlo cuando quieras en Ajustes, y debajo de cada uno pone exactamente a qué accede y qué pasa si lo dejas apagado.",
        "Type this and see what happens": "Escribe esto y mira qué pasa",
        "And when you cannot remember what you can type, open Settings → **What I can type**: it is all listed there.":
            "Y cuando no sepas qué se puede escribir, abre Ajustes → **Qué puedo escribir**: está todo listado.",
        "recommended": "recomendado",
        "If you leave it off: %@": "Si lo dejas apagado: %@",

        "We could not release that Mac. Try again in a moment.":
            "No pudimos liberar ese equipo. Intenta de nuevo en un momento.",
        "Activate BeLauncher": "Activa BeLauncher",
        "Lifetime licence · up to 3 Macs": "Licencia de por vida · hasta 3 Macs",
        "The key arrives by email when you buy. It is kept in your Keychain and BeLauncher works offline from here on.":
            "La clave llega por correo al comprar. Se guarda en tu Llavero y BeLauncher funciona sin conexión a partir de aquí.",
        "This licence is already on %@ Macs. Release one to activate this.":
            "Esta licencia ya está en %@ Macs. Libera uno para activar este.",
        "To release one, open it on that Mac and use Settings › Deactivate this Mac.":
            "Para liberar uno, ábrelo en ese Mac y usa Ajustes › Desactivar en este equipo.",
        "Release this Mac": "Liberar este Mac",

        "Search, calculate, convert, or type what you want to do":
            "Busca, calcula, convierte o escribe lo que quieres hacer",
        "BRAIN / RECENT": "CEREBRO / RECIENTE",
        "BEBRAIN / RECENT": "BEBRAIN / RECIENTE",
        "BEBRAIN QUICK ACTIONS": "ACCIONES RÁPIDAS BEBRAIN",
        "CLIPBOARD HISTORY": "HISTORIAL DEL PORTAPAPELES",
        "Open your brain": "Ver tu cerebro",
        "See the graph, recent work and what needs correcting":
            "Abre el grafo, el trabajo reciente y lo que necesita corrección",
        "Ask your brain": "Preguntar al cerebro",
        "Start with a question about decisions, people, projects or tasks":
            "Empieza con una pregunta sobre decisiones, personas, proyectos o tareas",
        "Keep something in the brain": "Guardar algo en el cerebro",
        "Write one sentence. It stays as a proposal until you confirm it":
            "Escribe una frase. Queda como propuesta hasta que la confirmes",
        "Get briefed before a meeting": "Prepararte antes de una reunión",
        "Pulls together decisions, commitments and recent context":
            "Junta decisiones, compromisos y contexto reciente",
        "Decide with the brain": "Decidir con el cerebro",
        "Ask what is still in force before choosing":
            "Pregunta qué sigue vigente antes de elegir",
        "Run a mission": "Ejecutar una misión",
        "Plan, approve, execute, then get a receipt":
            "Plan, aprobación, ejecución y recibo",
        "Ask for Pulse": "Pedir Pulso",
        "See what BeBrain thinks you should be looking at":
            "Ve lo que BeBrain cree que deberías estar mirando",
        "New quick note": "Nueva nota rápida",
        "Write freely and save it to your inbox as Markdown":
            "Escribe libremente y guárdala en tu inbox como Markdown",
        "Write a quick note": "Escribir una nota rápida",
        "A multiline Markdown note saved in your inbox":
            "Una nota Markdown con varias líneas guardada en tu inbox",
        "Open the Markdown note editor": "Abrir el editor de notas Markdown",
        "Write the fact you want to confirm": "Escribe el dato que quieres confirmar",
        "Graph, reader and recent work": "Grafo, lector y trabajo reciente",
        "Quick note": "Nota rápida",
        "Saved as Markdown in inbox": "Se guarda como Markdown en inbox",
        "⌘↩ Save": "⌘↩ Guardar",
        "Save note": "Guardar nota",
        "Open note editor: %@": "Abrir editor de notas: %@",
        "Talk to your knowledge": "Conversar con tu conocimiento",
        "Import file": "Importar archivo",
        "Add a file as evidence": "Añadir un archivo como evidencia",
        "Import pasted text": "Importar texto pegado",
        "Ask anything your Brain knows...": "Pregúntale cualquier cosa que sepa tu Brain...",
        "Sources": "Fuentes",
        "Pasted evidence": "Evidencia pegada",
        "The Brain has no evidence for that yet.": "El Brain aún no tiene evidencia sobre eso.",
        "The file is not readable text.": "El archivo no contiene texto legible.",
        "Import failed": "No se pudo importar",
        "Evidence imported": "Evidencia importada",
        "Imported evidence": "Evidencia importada",
        "Saved in your Brain.": "Guardado en tu Brain.",
        "Save in Brain": "Guardar en Brain",
        "Canvas saved": "Canvas guardado",
        "Canvas could not be saved": "No se pudo guardar el Canvas",
        "Save answer as note": "Guardar respuesta como nota",
        "Turn into mission": "Convertir en misión",
        "Open Canvas": "Abrir Canvas",
        "Mission plan": "Plan de misión",
        "Review what the Brain is about to prepare.":
            "Revisa lo que el Brain va a preparar.",
        "Nothing runs until you choose Run.":
            "Nada se ejecuta hasta que elijas Ejecutar.",
        "Run mission": "Ejecutar misión",
        "New Brain note": "Nueva nota del Brain",
        "Edit before saving it to your inbox.":
            "Edita antes de guardarla en tu inbox.",
        "Mission receipt": "Recibo de misión",
        "This is what actually happened.": "Esto es lo que ocurrió.",
        "Running…": "Ejecutando…",
        "The receipt is kept in this session.":
            "El recibo se conserva en esta sesión.",
        "New note": "Nueva nota",
        "Overview": "Resumen",
        "Graph": "Grafo",
        "Today in your Brain": "Hoy en tu Brain",
        "Read, question and turn what matters into action.":
            "Lee, pregunta y convierte lo importante en acción.",
        "Nodes": "Nodos",
        "Relations": "Relaciones",
        "Notes": "Notas",
        "Recent knowledge": "Conocimiento reciente",
        "Your Brain has no readable notes yet.":
            "Tu Brain aún no tiene notas legibles.",
        "Recent activity": "Actividad reciente",
        "The graph will appear here as the Brain learns.":
            "El grafo aparecerá aquí mientras el Brain aprende.",
        "Explore the full graph": "Explorar el grafo completo",
        "Inbox": "Inbox",
        "Nothing is waiting for review.": "No hay nada pendiente de revisar.",
        "Pending review": "Pendiente de revisar",
        "Needs transcription": "Necesita transcripción",
        "Clipboard capture": "Captura del portapapeles",
        "Remember in Brain": "Recordar en el Brain",
        "Remove from Inbox": "Quitar del Inbox",
        "Retry transcription": "Reintentar transcripción",
        "Retry unavailable": "No se puede reintentar",
        "The original audio is no longer at its saved path.":
            "El audio original ya no está en la ruta guardada.",
        "Transcription saved": "Transcripción guardada",
        "Retry failed": "Falló el reintento",
        "All": "Todo",
        "Inbox filter": "Filtro del Inbox",
        "Open original": "Abrir original",
        "Propose memory": "Proponer memoria",
        "Mark reviewed": "Marcar revisada",
        "Retry": "Reintentar",
        "prepare Python": "preparar Python",
        "create the local environment": "crear el entorno local",
        "install the voice engine": "instalar el motor de voz",
        "download the model": "descargar el modelo",
        "checking the local server": "comprobar el servidor local",
        "install Ollama": "instalar Ollama",
        "start Ollama": "iniciar Ollama",
        "download model": "descargar el modelo",
        "check free disk space": "comprobar el espacio libre",
        "prepare the local voice runtime": "preparar el motor de voz local",
        "download the local bootstrapper": "descargar el instalador local",
        "Voice note awaiting transcription": "Nota de voz pendiente de transcripción",
        "Call awaiting transcription": "Llamada pendiente de transcripción",
        "Transcription failed: %@": "La transcripción falló: %@",
        "Voice note saved, but transcription needs attention.": "La nota de voz se guardó, pero la transcripción necesita atención.",
        "The local model service is not answering. Start it and try again.": "El servicio de modelos local no responde. Inícialo y vuelve a intentarlo.",
        "%@ is not answering. Start it and try again.": "%@ no responde. Inícialo y vuelve a intentarlo.",
        "The model service returned an unexpected response (%@). Try again.": "El servicio de modelos devolvió una respuesta inesperada (%@). Vuelve a intentarlo.",
        "This install needs about %@, but only %@ is free on the disk.": "Esta instalación necesita unos %@, pero solo hay %@ libres en el disco.",
        "No local transcription provider could read this audio. %@": "Ningún proveedor local de transcripción pudo leer este audio. %@",
        "unpack the local runtime": "descomprimir el runtime local",
        "Could not %@ (code %@).": "No se pudo %@ (código %@).",
        "Cancelled before all steps finished.": "Cancelada antes de terminar todos los pasos.",
        "Brain": "Brain",
        "Cancel command": "Cancelar comando",
        "%@ · %@": "%@ · %@",
        "Needs attention": "Necesita atención",
        "Nothing needs attention right now.": "Ahora mismo no hay nada que requiera atención.",
        "Ask Brain": "Preguntar al Brain",
        "Brain conversation": "Conversación con el Brain",
        "Question cancelled.": "Pregunta cancelada.",
        "Mission result: %@": "Resultado de misión: %@",
        "Mission result could not be saved": "No se pudo guardar el resultado de la misión",
        "Mission outcome could not be saved": "No se pudo guardar el resultado de la misión",
        "Mission outcome: %@": "Resultado de misión: %@",
        "%@ passages written": "%@ fragmentos escritos",
        "%@ of %@ items · %@ passages": "%@ de %@ elementos · %@ fragmentos",
        "Capture is waiting for its next background pass.": "La captura espera su siguiente pasada en segundo plano.",
        "Capture is reading permitted sources…": "La captura está leyendo las fuentes permitidas…",
        "Capture is reading %@…": "La captura está leyendo %@…",
        "Capture is assembling the Brain…": "La captura está ensamblando el Brain…",
        "Capture is assembling %@ into the Brain…": "La captura está ensamblando %@…",
        "Capture is writing %@.": "La captura está escribiendo %@.",
        "Capture is writing %@: %@.": "La captura está escribiendo %@: %@.",
        "Background capture is deferred while the Mac is conserving resources.":
            "La captura en segundo plano espera mientras el Mac ahorra recursos.",
        "Capture is deferred": "La captura está aplazada",
        "Last capture completed: %@.": "Última captura completada: %@.",
        "Last run: %@ · %@ passages · %@ s": "Última pasada: %@ · %@ fragmentos · %@ s",
        "Capture is paused. Nothing is being read.": "La captura está pausada. No se está leyendo nada.",
        "Last capture needs attention.": "La última captura necesita atención.",
        "A previous capture will resume safely.": "Una captura anterior continuará de forma segura.",
        "Capture has not run yet.": "La captura todavía no se ha ejecutado.",
        "Capture status": "Estado de captura",
        "Capture is not running": "La captura no está activa",
        "Capture is waiting": "La captura está esperando",
        "Capture is reading sources": "La captura está leyendo fuentes",
        "Capture is assembling the Brain": "La captura está ensamblando el Brain",
        "Capture is writing": "La captura está escribiendo",
        "Capture completed": "Captura completada",
        "Capture is paused": "La captura está pausada",
        "Capture needs attention": "La captura necesita atención",
        "%@ fragments in the last pass": "%@ fragmentos en la última pasada",
        "Nothing has been written by the background pass yet.":
            "La pasada en segundo plano todavía no ha escrito nada.",
        "Knowledge sources": "Fuentes de conocimiento",
        "Safari and Chrome": "Safari y Chrome",
        "AI conversations": "Conversaciones con IA",
        "Audio and calls": "Audio y llamadas",
        "Files": "Archivos",
        "Applications": "Aplicaciones",
        "Apple Notes": "Apple Notes",
        "Apple Note": "Nota de Apple",
        "Messages and WhatsApp": "Mensajes y WhatsApp",
        "Mail and work chats": "Mail y chats de trabajo",
        "Apple Messages": "Apple Messages",
        "WhatsApp": "WhatsApp",
        "Apple Mail": "Apple Mail",
        "I cannot read Apple Messages. macOS protects its local database; give BeLauncher Full Disk Access in System Settings, Privacy & Security.":
            "No puedo leer Apple Messages. macOS protege su base local; concede a BeLauncher Acceso total al disco en Ajustes del Sistema, Privacidad y seguridad.",
        "Apple Messages could not be read because its local database is unavailable.":
            "No se pudo leer Apple Messages porque su base local no está disponible.",
        "I cannot read Apple Notes. macOS protects its local database; give BeLauncher Full Disk Access in System Settings, Privacy & Security.":
            "No puedo leer Apple Notes. macOS protege su base local; concede a BeLauncher Acceso total al disco en Ajustes del Sistema, Privacidad y seguridad.",
        "Apple Notes could not be read because its local database is unavailable.":
            "No se pudo leer Apple Notes porque su base local no está disponible.",
        "All sources": "Todas las fuentes",
        "Gmail, Outlook and work chats": "Gmail, Outlook y chats de trabajo",
        "Recent text messages from the local Messages database; attachments are excluded.":
            "Mensajes de texto recientes de la base local de Messages; los adjuntos quedan fuera.",
        "Plain snippets from the local Notes store; encrypted payloads are excluded.":
            "Snippets de texto plano del almacén local de Notes; los contenidos cifrados quedan fuera.",
        "Recent relevant messages with a reference to the original local .emlx file.":
            "Mensajes recientes relevantes con referencia al archivo .emlx local original.",
        "Planned connectors for Gmail, Outlook, Slack, Teams and Discord.":
            "Conectores previstos para Gmail, Outlook, Slack, Teams y Discord.",
        "Copied text, images and files, when capture is enabled.":
            "Texto, imágenes y archivos copiados, cuando la captura está activa.",
        "Page titles and URLs from browser history.":
            "Títulos y URLs de las páginas del historial del navegador.",
        "Local assistant sessions in the configured sessions folder.":
            "Sesiones locales del asistente en la carpeta configurada.",
        "Meeting titles, times and attendees after permission.":
            "Títulos, horas y asistentes de reuniones después de conceder permiso.",
        "Explicit recordings and selected audio folders; never background listening.":
            "Grabaciones explícitas y carpetas de audio elegidas; nunca escucha en segundo plano.",
        "Search by filename through Spotlight; content is not automatically indexed yet.":
            "Búsqueda por nombre mediante Spotlight; el contenido todavía no se indexa automáticamente.",
        "Installed apps for launcher search; passive app activity is not connected yet.":
            "Apps instaladas para buscar desde el launcher; la actividad pasiva aún no está conectada.",
        "Installed apps for search, plus frontmost-app activity metadata when capture is enabled.":
            "Apps instaladas para buscar, más metadatos de la app activa cuando la captura está habilitada.",
        "Planned connector. Nothing is read yet.": "Conector previsto. Todavía no se lee nada.",
        "Planned connector with separate permission and privacy controls.":
            "Conector previsto con permisos y controles de privacidad separados.",
        "WhatsApp is detected when present, but this build only reads it after a supported local message store is verified.":
            "WhatsApp se detecta cuando está presente, pero esta versión solo lo lee después de verificar un almacén local de mensajes soportado.",
        "WhatsApp is installed, but no supported readable local message store was found.":
            "WhatsApp está instalado, pero no se encontró un almacén local de mensajes legible y soportado.",
        "Planned connector for Mail, Slack, Teams and Discord.":
            "Conector previsto para Mail, Slack, Teams y Discord.",
        "I cannot read Apple Mail. macOS protects its local mail store; give BeLauncher Full Disk Access in System Settings, Privacy & Security.":
            "No puedo leer Apple Mail. macOS protege su almacén local; concede a BeLauncher Acceso total al disco en Ajustes del Sistema, Privacidad y seguridad.",
        "Connected": "Conectado",
        "Available": "Disponible",
        "Manual": "Manual",
        "Planned": "Previsto",
        "Unsupported": "No soportado",
        "Launcher ready in %@ ms": "Launcher listo en %@ ms",
        "Deep local sources ready": "Fuentes locales profundas listas",
        "Full Disk Access needed for Mail, Messages and Notes":
            "Hace falta Acceso total al disco para Mail, Messages y Notes",
        "Open settings": "Abrir ajustes",
        "What the Brain can read and keep": "Lo que el Brain puede leer y conservar",
        "Connected and available": "Conectadas y disponibles",
        "Deep local sources are ready": "Las fuentes locales profundas están listas",
        "Full Disk Access unlocks local Mail, Messages and Notes":
            "Acceso total al disco desbloquea Mail, Messages y Notes locales",
        "Nothing leaves this Mac. Each connector keeps only relevant evidence and a reference to its original source.":
            "Nada sale de este Mac. Cada conector conserva solo evidencia relevante y una referencia a su fuente original.",
        "Allow": "Permitir",
        "Coming later": "Más adelante",
        "Detected, not supported": "Detectado, no soportado",
        "Disable source": "Desactivar fuente",
        "Enable source": "Activar fuente",
        "Paused by you": "Pausada por ti",
        "Not read yet": "Todavía no leída",
        "Sync now": "Sincronizar ahora",
        "Last read: %@ items · needs attention": "Última lectura: %@ elementos · necesita atención",
        "Retry after %@ · needs attention": "Reintento después de %@ · necesita atención",
        "The app closed before this action finished.": "La app se cerró antes de terminar esta acción.",
        "%@ action(s) were interrupted and need your review.": "%@ acción(es) quedaron interrumpidas y necesitan revisión.",
        "Review": "Revisar",
        "Unavailable": "No disponible",
        "Ready": "Listo",
        "Everything stays on this Mac": "Todo se queda en este Mac",
        "Current document: %@": "Documento actual: %@",
        "The question will use this document as context.": "La pregunta usará este documento como contexto.",
        "The receipt is saved in your Brain and can be searched later.":
            "El recibo se guarda en tu Brain y puedes buscarlo después.",
        "Discard changes": "Descartar cambios",
        "Important": "Importante",
        "No flows yet. A flow chains steps under one keyword.":
            "Todavía no hay flujos. Un flujo encadena pasos bajo una palabra clave.",
        "Edit steps": "Editar pasos",
        "Focus mode": "Modo concentración",
        "Create with first step": "Crear con el primer paso",
        "Steps run in order. “Run shortcut” calls a shortcut you already made in the Shortcuts app — that is how a flow silences notifications or sets a Focus. BeLauncher never runs scripts of its own.":
            "Los pasos se ejecutan en orden. «Ejecutar atajo» llama a un atajo que ya creaste en Atajos; así se silencian notificaciones o se activa un modo de concentración. BeLauncher nunca ejecuta scripts propios.",
        "Choose…": "Elegir…",
        "Pick…": "Elegir…",
        "Open app": "Abrir aplicación",
        "Open URL": "Abrir URL",
        "Open file": "Abrir archivo",
        "Copy text": "Copiar texto",
        "Paste snippet": "Pegar snippet",
        "Run shortcut": "Ejecutar atajo",
        "Start timer": "Iniciar temporizador",
        "Wait": "Esperar",
        "text to copy": "texto para copiar",
        "snippet keyword": "palabra clave del snippet",
        "Shortcut name": "nombre del atajo",
        "label": "etiqueta",
        "seconds": "segundos",
        "Pick the app this step should open.": "Elige la aplicación que debe abrir este paso.",
        "%@ min": "%@ min",
        "Needs setup": "Necesita configuración",
        "Last read: %@ items · %@": "Última lectura: %@ elementos · %@",
        "App activity metadata and files opened through BeLauncher. It does not read window or file contents yet.":
            "Metadatos de actividad de apps y archivos abiertos desde BeLauncher. Todavía no lee el contenido de ventanas ni archivos.",
        "Meeting context after Calendar permission, plus what you copy while capture is enabled.":
            "Contexto de reuniones después del permiso de Calendario, más lo que copias cuando la captura está activa.",
        "Back to Brain": "Volver al Brain",
        "Reading your Brain": "Leyendo tu Brain",
        "Markdown you own": "Markdown que te pertenece",
        "Create a snippet: %@": "Crear snippet: %@",
        "Trigger, e.g. ;firma": "Disparador, por ejemplo ;firma",
        "Name": "Nombre",
        "New snippet": "Nuevo snippet",
        "Create a snippet": "Crear snippet",
        "Choose the trigger. The clipboard text is already loaded.":
            "Elige el disparador. El texto del portapapeles ya está cargado.",
        "Create": "Crear",
        "Snippet not created": "No se creó el snippet",
        "A trigger and a name are required.": "El disparador y el nombre son obligatorios.",
        "Snippet created": "Snippet creado",
        "what did we decide about ": "qué decidimos sobre ",
        "remember that ": "recordar que ",
        "prepare me for ": "prepárame para ",
        "Start typing this": "Empezar con esto",
        "Showing the full local graph.": "Mostrando todo el grafo local.",
        "Showing the last 7 days.": "Mostrando los últimos 7 días.",
        "Find": "Encontrar",
        "Anything on your Mac, before you finish typing.":
            "Cualquier cosa de tu Mac antes de que termines de escribir.",
        "Ask": "Preguntar",
        "Ask your own memory, not a generic model.":
            "Pregúntale a tu propia memoria, no a un modelo genérico.",
        "Remember": "Recordar",
        "Save what matters as a commit, not a dump.":
            "Guarda lo que importa como commit, no como vertedero.",
        "Prepare": "Preparar",
        "Arrive with the context already gathered.": "Llega con el contexto ya reunido.",
        "Decide": "Decidir",
        "Bring back only what is still in force.": "Trae solo lo que sigue vigente.",
        "Act": "Actuar",
        "Run the mission: plan, approval and receipt.":
            "Ejecuta la misión: plan, aprobación y recibo.",
        "Pulse": "Pulso",
        "pulse": "pulso",
        "The one that asks instead of answering.":
            "El único que pregunta en vez de responder.",
        "local graph": "grafo local",
        "vectors": "vectores",
        "chunks": "chunks",
        "The search bar is the surface. Behind it is a local brain that remembers, knows what still stands and acts.":
            "La barra de búsqueda es la superficie. Detrás hay un cerebro local que recuerda, sabe qué sigue vigente y actúa.",
        "what do we know about ": "qué sabemos de ",
        "Recent work": "Trabajo reciente",
        "last 7 days": "últimos 7 días",
        "Full graph": "Grafo completo",
        "Four levels of truth": "Cuatro niveles de verdad",
        "Evidence": "Evidence",
        "What happened, as-is.": "Lo que pasó, tal cual.",
        "Extracted Memory": "Extracted Memory",
        "Distilled, not confirmed yet.": "Destilado, todavía sin confirmar.",
        "Committed Memory": "Committed Memory",
        "What you confirm as true.": "Lo que confirmas como cierto.",
        "Outcome Memory": "Outcome Memory",
        "Truth closed by the result.": "La verdad cerrada por el resultado.",
        "Pick something in the graph": "Elige algo en el grafo",
        "Every node can be opened, read, marked important, forgotten or corrected. The point is not to admire the graph; it is to keep the brain honest.":
            "Cada nodo se puede abrir, leer, marcar importante, olvidar o corregir. La idea no es admirar el grafo: es mantener honesto al cerebro.",
        "BeBrain captures": "BeBrain captura",
        "Pages you visit": "Páginas que visitas",
        "Documents you edit": "Documentos que editas",
        "Code you write": "El código que escribes",
        "What you copy and paste": "Lo que copias y pegas",
        "Meetings, if you turn them on": "Reuniones, si las activas",
        "Nothing for “%@”": "Nada para «%@»",
        "Try: **2+2** calculates · **10 km to mi** converts · **f report** finds files · **focus** starts a block of work · **what did we decide about …** asks your brain.":
            "Prueba: **2+2** calcula · **10 km to mi** convierte · **f informe** busca archivos · **enfoque** arranca un bloque de trabajo · **qué decidimos sobre …** pregunta a tu cerebro.",
        "BeLauncher could not read its own database":
            "BeLauncher no pudo leer su base de datos",
        "Clipboard history": "Historial del portapapeles",
        "Here is what it would do": "Esto es lo que haría",
        "Nothing runs until you approve it, and afterwards you get a receipt of what changed.":
            "Nada se ejecuta hasta que lo apruebes, y después verás un recibo de lo que cambió.",
        "The first time each day takes a few seconds while the model loads into memory. After that it starts writing almost instantly.":
            "La primera vez del día tarda unos segundos mientras el modelo se carga en memoria. Después empieza a escribir casi al instante.",
        "No action matches": "Ninguna acción coincide",
        "Drag it into any app": "Arrástralo a cualquier app",
        "Drag from the image": "Arrastra desde la imagen",

        // Missions
        "Get me working": "Ponerme a trabajar",
        "Silences everything, opens your things and starts a block of work.":
            "Silencia, abre lo tuyo y arranca un bloque de trabajo.",
        "Close the day": "Cerrar el día",
        "Goes over what is left and keeps what you learned.":
            "Repasa lo pendiente y guarda lo aprendido.",
        "Turn notes into memory": "Convertir notas en memoria",
        "Pulls decisions and commitments out of your notes and proposes them.":
            "Saca decisiones y compromisos de tus notas y los propone.",
        "Tidy up Downloads": "Ordenar las descargas",
        "Shows you what is in there and lets you move it or bin it.":
            "Enseña qué hay y te deja moverlo o tirarlo.",
        "Turn this into a proposal": "Convertir esto en una propuesta",
        "Builds the proposal from whatever you have copied.":
            "Monta la propuesta con lo que tengas copiado.",
        "Builds the proposal for %@.": "Monta la propuesta para %@.",
        "Answer what is urgent": "Responder lo urgente",
        "Looks at what is overdue or nearly due and tells you where to start.":
            "Mira qué está vencido o a punto y te dice por dónde empezar.",
        "Publish this idea": "Publicar esta idea",
        "Turns the note into something publishable and leaves it copied.":
            "Convierte la nota en algo publicable y te lo deja copiado.",
        "Clear the desktop": "Limpiar el escritorio",
        "Opens the desktop so you can see what is in the way.":
            "Abre el escritorio para que veas qué sobra.",
        "Start the week": "Arrancar la semana",
        "Goes over open commitments and whatever is going stale.":
            "Repasa compromisos abiertos y lo que se está pudriendo.",
        "Confirm a memory": "Confirmar una memoria",
        "Discard a proposal": "Descartar una propuesta",
        "Quick Look": "Vista rápida",
        "Open with another app": "Abrir con otra app",
        "Mission cancelled": "Misión cancelada",
        "Request cancelled": "Petición cancelada",
        "Close the window": "Cerrar la ventana",
        "Undo the confirmed memory": "Revertir la memoria confirmada",
        "Changed:": "Cambió:",
        "50-minute timer": "Temporizador de 50 minutos",
        "Focus block": "Bloque de enfoque",
        "Pull out what is left today": "Sacar lo pendiente de hoy",
        "End of day": "Cierre del día",
        "Propose them to the brain": "Proponerlas al cerebro",
        "Meeting notes": "Notas de reunión",
        "Build the proposal": "Montar la propuesta",
        "Look at what is overdue or nearly due": "Mirar qué está vencido o a punto",
        "Turn it into something publishable": "Convertirlo en algo publicable",
        "Open the desktop": "Abrir el escritorio",
        "Go over what is going stale": "Repasar lo que se está pudriendo",
        "Turn on Do Not Disturb": "Activar No molestar",
        "Propose it as a memory": "Proponerlo como memoria",
        "Pull out decisions and commitments": "Sacar decisiones y compromisos",
    ]

    // MARK: - Results, actions and the panel

    static let results: [String: String] = [
        // The launcher surface
        "Search": "Búsqueda",
        "To confirm": "Por confirmar",
        "Mission": "Misión",
        "Where every window is, on which display and how big":
            "Dónde está cada ventana, en qué pantalla y de qué tamaño",
        "Save the note": "Guardar la nota",
        "Until you turn it off from the menu bar":
            "Hasta que lo apagues desde la barra de menús",
        "It switches itself off when it finishes": "Se apaga solo al terminar",
        "Nothing is working harder than it should": "Nada está trabajando de más",
        "Nothing called “%@”": "Nada llamado «%@»",
        "Working memory": "Memoria de trabajo",
        "It is kept as a proposal until you confirm it":
            "Se guardará como propuesta hasta que la confirmes",
        "Nothing to flag": "Nada que señalar",
        "%@ thing(s) to look at": "%@ cosa(s) que mirar",
        "The brain is in order": "El cerebro está en orden",
        "on the last thing you copied · %@": "sobre lo último que copiaste · %@",
        "%@ steps · you see the plan before anything is touched":
            "%@ pasos · te enseño el plan antes de tocar nada",
        "Proposal · would replace %@ memory/memories":
            "Propuesta · sustituiría %@ memoria(s)",
        "macOS Shortcut": "Atajo de macOS",
        "Places the active window": "Coloca la ventana activa",
        "Asks you first": "Pide confirmación",
        "System command": "Comando del sistema",
        "↩ copies it": "↩ lo copia",

        // The detail panel
        "Used": "Usos",
        "Unexpanded": "Sin expandir",
        "From": "Origen",
        "Unknown": "Desconocido",
        "Copied": "Copiado",
        "Length": "Longitud",
        "%@ characters": "%@ caracteres",
        "Keyword": "Palabra clave",
        "Steps": "Pasos",
        "Sum": "Operación",
        "Using": "Consumo",
        "Runs": "Se ejecuta",
        "in the background, with a receipt": "en segundo plano, con recibo",
        "Path": "Ruta",
        "Kind": "Tipo",
        "Browser bookmark": "Marcador del navegador",
        "First": "Antes de nada",
        "You see the plan and can cancel": "Verás el plan y podrás cancelar",
        "Afterwards": "Después",
        "A receipt of what changed": "Un recibo de lo que cambió",
        "Will work on": "Se hará sobre",
        "Based on": "Basado en",
        "Where from": "De dónde",
        "Memory": "Memoria",
        "In force": "Vigente",
        "Yes": "Sí",
        "No": "No",
        "Owner": "Dueño",
        "Source": "Fuente",
        "Why": "Motivo",
        "Would replace": "Sustituiría",
        "Note": "Nota",
        "Nothing enters the brain without you confirming it.":
            "Nada entra al cerebro sin que lo confirmes.",
        "Shortcuts app": "App Atajos",
        "You made it; BeLauncher only calls it by name.":
            "Lo creaste tú; BeLauncher solo lo invoca por nombre.",
        "Needs": "Requiere",
        "Accessibility permission": "Permiso de Accesibilidad",
        "Confirmation": "Confirmación",
        "Yes, before it runs": "Sí, antes de ejecutar",
        "Not needed": "No hace falta",
        "Type a term after the keyword.": "Escribe un término después de la palabra clave.",

        // The pulse
        "Two live versions of %@": "Dos versiones vigentes sobre %@",
        "“%1$@” and “%2$@” are both in force. One should be replacing the other.":
            "«%1$@» y «%2$@» están las dos en vigor. Una debería sustituir a la otra.",
        "Overdue commitment": "Compromiso vencido",
        "Unreviewed for %@ months": "Sin revisar desde hace %@ meses",
        "“%@”. Is it still true?": "«%@». ¿Sigue siendo cierto?",
        "Decision with nothing behind it": "Decisión sin respaldo",
        "“%@” has no source and no evidence. A year from now nobody will know why it was taken.":
            "«%@» no tiene fuente ni evidencia. Dentro de un año nadie sabrá por qué se tomó.",
        "Nobody owns it": "Sin responsable",
        "“%@” has no owner.": "«%@» no tiene dueño.",
        "Expired decision with no replacement": "Decisión caducada sin reemplazo",
        "“%@” stopped being in force and nobody recorded what replaces it.":
            "«%@» dejó de estar vigente y nadie registró qué la sustituye.",
        "Nothing to flag. No contradictions, no overdue commitments, and nothing left unreviewed for half a year.":
            "Nada que señalar. Ninguna contradicción, ningún compromiso vencido y nada sin revisar desde hace medio año.",

        // Workspaces
        "and %@ more": "y %@ más",
        "It was saved with %1$@ displays and there are %2$@ now. Anything that fell outside is pulled back onto the one you have.":
            "Se guardó con %1$@ pantallas y ahora hay %2$@. Lo que quedaba fuera se traerá a la que tienes.",
        "Not open: %@. Everything else still gets placed.":
            "No están abiertas: %@. El resto sí se coloca.",
    ]

    // MARK: - System and window commands

    static let system: [String: String] = [
        "Your brain": "Tu cerebro",
        "Lock the screen": "Bloquear pantalla",
        "Turn the display off": "Apagar la pantalla",
        "Put the Mac to sleep": "Suspender el Mac",
        "Screen saver": "Salvapantallas",
        "Switch light or dark mode": "Cambiar modo claro/oscuro",
        "Focus: do not disturb": "Concentración: no molestar",
        "Empty the Trash": "Vaciar la papelera",
        "Open the Trash": "Abrir la papelera",
        "Open Downloads": "Abrir Descargas",
        "Open the Desktop folder": "Abrir la carpeta Escritorio",
        "Open your home folder": "Abrir carpeta personal",
        "Show the desktop": "Mostrar el escritorio",
        "Mute the sound": "Silenciar el sonido",
        "Turn Wi-Fi on or off": "Activar o desactivar el wifi",
        "Turn Bluetooth on or off": "Activar o desactivar Bluetooth",
        "Eject disks": "Expulsar discos",
        "Log out": "Cerrar sesión",
        "Restart the Mac": "Reiniciar el Mac",
        "Shut the Mac down": "Apagar el Mac",
        "Restart BeLauncher": "Reiniciar BeLauncher",
        "Quit BeLauncher": "Salir de BeLauncher",
        "Window: left half": "Ventana: mitad izquierda",
        "Window: right half": "Ventana: mitad derecha",
        "Window: top half": "Ventana: mitad superior",
        "Window: bottom half": "Ventana: mitad inferior",
        "Window: top left corner": "Ventana: esquina superior izquierda",
        "Window: top right corner": "Ventana: esquina superior derecha",
        "Window: bottom left corner": "Ventana: esquina inferior izquierda",
        "Window: bottom right corner": "Ventana: esquina inferior derecha",
        "Window: left third": "Ventana: tercio izquierdo",
        "Window: centre third": "Ventana: tercio central",
        "Window: right third": "Ventana: tercio derecho",
        "Window: left two thirds": "Ventana: dos tercios izquierda",
        "Window: centred two thirds": "Ventana: dos tercios centrados",
        "Window: right two thirds": "Ventana: dos tercios derecha",
        "Window: maximise": "Ventana: maximizar",
        "Window: almost maximise": "Ventana: casi maximizar",
        "Window: centre": "Ventana: centrar",
        "Window: next display": "Ventana: pantalla siguiente",
        "Window: previous display": "Ventana: pantalla anterior",
    ]

    // MARK: - AI verbs

    static let verbs: [String: String] = [
        "Translate to Spanish": "Traducir al español",
        "Translate to English": "Traducir al inglés",
        "Summarise": "Resumir",
        "Turn into bullets": "Convertir en puntos",
        "Fix spelling and grammar": "Corregir ortografía y gramática",
        "Make it shorter": "Acortar",
        "Draft a reply": "Redactar una respuesta",
        "Explain this": "Explicar",
        "Format JSON": "Formatear JSON",
        "Turn into a table": "Convertir en tabla",
        "Make it publishable": "Convertir en algo publicable",
        "Review the week": "Repasar la semana",
        "Pull out the tasks": "Sacar las tareas",
    ]

    // MARK: - Errors and everything that went wrong

    static let errors: [String: String] = [
        // The five MCP steps and their failures
        "The assistant knows about BeLauncher": "El asistente conoce a BeLauncher",
        "The process starts": "El proceso arranca",
        "The opening handshake completes": "Se completa el saludo inicial",
        "The tools show up": "Aparecen las herramientas",
        "A real call brings data back": "Una llamada real trae datos",
        "It is not in that client's configuration. Press Connect in Settings.":
            "No está en la configuración de ese cliente. Pulsa conectar en Ajustes.",
        "The process did not start (%@). Check that BeLauncher is still installed at that path.":
            "El proceso no arrancó (%@). Comprueba que BeLauncher siga instalado en esa ruta.",
        "No answer to the opening handshake (initialize). The process may have hung, or closed before replying.":
            "No contestó al saludo inicial (initialize). El proceso puede haberse colgado o haberse cerrado antes de responder.",
        "It answered the handshake with something that is not valid JSON.":
            "Contestó al saludo con algo que no es JSON válido.",
        "The handshake came back with an error: %@.":
            "El saludo devolvió un error: %@.",
        "The handshake replied with no protocolVersion: it does not speak MCP.":
            "El saludo respondió sin protocolVersion: no habla el protocolo MCP.",
        "No answer when asked for the tool list (tools/list).":
            "No contestó al pedir la lista de herramientas (tools/list).",
        "The tool list is not valid JSON.": "La lista de herramientas no es JSON válido.",
        "Asking for the tool list came back with an error: %@.":
            "Pedir la lista de herramientas devolvió un error: %@.",
        "The reply carries no tool list at all.":
            "La respuesta no trae ninguna lista de herramientas.",
        "The server answered but announced zero tools: the assistant would have nothing to call.":
            "El servidor respondió pero anunció cero herramientas: el asistente no tendría nada que llamar.",
        "No answer to the test call (tools/call).":
            "No contestó a la llamada de prueba (tools/call).",
        "The reply to the test call is not valid JSON.":
            "La respuesta a la llamada de prueba no es JSON válido.",
        "The test call came back with an error: %@.":
            "La llamada de prueba devolvió un error: %@.",
        "The reply carries no result.": "La respuesta no trae resultado.",
        "The tool ran but came back with an internal error.":
            "La herramienta se ejecutó pero devolvió un error interno.",
        "The tool ran but came back with an error: “%@”.":
            "La herramienta se ejecutó pero devolvió un error: «%@».",
        "The tool replied with no content: the assistant would have nothing to read.":
            "La herramienta respondió sin contenido: el asistente no recibiría nada que leer.",
        "The tool replied with empty text.": "La herramienta respondió con el texto vacío.",
        "The test datum could not be put into the index, so this call proves nothing. Rebuild the index under “Brain status” and check again.":
            "No se pudo dejar el dato de prueba en el índice, así que esta llamada no demuestra nada. Rehaz el índice en «Estado del cerebro» y vuelve a comprobar.",
        "It answered, but with no real datum: it said “%@”. The circuit works, the content did not arrive.":
            "Contestó, pero sin dato real: dijo «%@». El circuito funciona, el contenido no llegó.",
        "%@: really connected.": "%@: conectado de verdad.",
        "%@: unchecked.": "%@: sin comprobar.",
        "%1$@: fails at “%2$@”. %3$@": "%1$@: falla en «%2$@». %3$@",
        "really connected": "conectado de verdad",
        "not connected": "no conectado",
    ]
}
