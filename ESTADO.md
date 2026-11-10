# Estado del proyecto y qué falta

Documento de relevo. Existe porque el trabajo se detuvo en un punto concreto y
quien lo retome (o el propio autor dentro de un mes) necesita saber **exactamente
dónde está el corte** sin reconstruirlo desde cero.

Fecha del corte: **ronda 21 (actualizaciones desde GitHub Releases)**.
Última verificación: **455 comprobaciones** en los once comandos de Linux
(`verify_core` 209, `verify_engine` 51, `verify_linux_audio` 40,
`verify_soundboard` 25, etc.) y **23 pruebas de widgets** con `flutter test`,
todas en verde. La compilación y
arranque del `.exe` en GitHub Actions siguen vigentes (run `42753682644`,
`verify_core` 210, `verify_soundboard` 18 y `verify_update` 29 en Windows, icono 32x32, `ffplay.exe` incluido y arranque correcto). La interfaz
Flutter se ejecutó de verdad, con runner Linux, capturó audio real por
PulseAudio/PipeWire, por ALSA y emitió contra un servidor Icecast simulado.

En esta ronda se unificó el audio en **una sola captura**: el mismo PCM alimenta
el vúmetro y el codificador, la ganancia se aplica en Dart y moverla ya no
reinicia FFmpeg ni corta la emisión. Antes había dos capturas (un monitor fuera
del aire y otra al emitir) y por eso el vúmetro cambiaba de fuente al entrar al
aire.

La ronda 18 añade la protección contra el **bloqueo de pantalla** en Linux y la
reapertura automática de la captura si el audio se queda mudo (ver más abajo).

La ronda 19 agrega un **icono propio** (ventana, ejecutable de Windows y
lanzadores), deja **sin preseleccionar ninguna entrada de audio** (la app no
abre el micrófono hasta que el DJ elige uno) y
simplifica el menu de tipo de servidor a **Icecast2**. Tambien elimina toda
comparacion con otros emisores de la interfaz y de `THIRD_PARTY.md`.

La ronda 20 implementa la **fase 1 del soundboard**: ocho pads, mezcla en vivo
antes del vúmetro/codificador, ducking, loop, teclas 1-8/F1-F8, persistencia y
**cue local** por FFmpeg (Linux) o `ffplay` (Windows). El monitoreo completo de
la mezcla queda para la fase siguiente.

La ronda 21 agrega el **actualizador**: comprueba GitHub Releases al arrancar y
cada seis horas, muestra un aviso, descarga el ZIP de Windows, verifica el
SHA-256 y lanza un actualizador que reemplaza la carpeta portable y reabre la
app. El repositorio debe ser publico; la primera instalacion se hace a mano.

Tambien se agrego la **web oficial** en `site/`, publicada con GitHub Pages en
<https://envidia1972-create.github.io/xtreme_studio/>. Incluye descarga dinamica
de la ultima release, cambios, tutoriales, YouTube, donaciones (PayPal), un
formulario que abre un issue de GitHub y un manual web/PDF con la instalacion,
configuracion, soundboard, AAC+ y actualizaciones.

Tambien se corrigio el **handshake de Shoutcast**: la fuente se conecta al
puerto base + 1 (el puerto del perfil es el de oyentes), envia la contrasena
sola, sin usuario ni `#1`, y conserva los dos puntos si la clave los contiene.
Antes se conectaba al puerto base y se enviaba `usuario:clave`, lo que producia
`HTTP 500 Invalid request` y parecia una clave rechazada.

Además se corrigió el **cambio de título en Shoutcast v2**: `/admin.cgi` se
pedía al puerto `+1` (que en v1 es el de oyentes), pero el DNAS v2 atiende
fuentes, oyentes y administración en el mismo `portbase`. Ahora se prueban los
puertos candidatos, se usan las credenciales de administración si están
configuradas y se comprueba la respuesta del servidor (antes bastaba con abrir
el socket para darlo por bueno).

El flujo se reprodujo con la app real, tono de 440 Hz en un sink virtual y
pulsaciones con XTest: un solo "NIVEL DE ENTRADA", misma captura antes y al
aire, y al mover la ganancia de -4 a 0 dB el vúmetro pasó de -31,1 a -27,1 dBFS
con los PID de captura y codificador intactos, sin reconexión y con bytes
crecientes en el servidor. Al salir del aire el codificador se detuvo y la
captura siguió midiendo; al cerrar la app no quedó ningún FFmpeg huérfano.
Capturas actualizadas: `docs/screenshots/linux-nivel-idle.png` y
`docs/screenshots/linux-al-aire.png`.

---

## Qué está hecho y verificado

| Área | Estado |
|---|---|
| Gestor de emisoras (crear, editar, duplicar, borrar) | Verificado |
| Importar y exportar perfiles (sin contraseña en claro) | Verificado |
| Icecast 2 + Shoutcast v1/v2 (handshake propio, sin ffmpeg) | Verificado, incluido servidor simulado |
| Credenciales DPAPI en Windows | Verificado en Windows (GitHub Actions, `verify_core`) |
| Credenciales con permisos `0600` en Linux/macOS | Verificado y usado por la app en Linux |
| "Probar conexión" con diagnóstico por código HTTP | Verificado |
| Captura y codificación por FFmpeg | **Verificada con audio real en Linux**, con captura y codificador como procesos separados |
| Motor de emisión, reconexión y detección de caída | Verificado con FFmpeg simulado y con audio real |
| Red estancada (backpressure) y conexión “zombi” | Verificado con servidor que deja de leer |
| TLS con certificado autofirmado | Verificado con certificado real embebido |
| Metadatos por `/admin/metadata` (Icecast/Zeno.fm) | Verificado con servidor simulado y sonda real |
| Un solo vúmetro, alimentado por la misma captura antes y después de salir al aire | Verificado con PCM sintético y con audio real |
| Grabación local | Verificada con audio real; usa el mismo codec/bitrate que el stream |
| Ganancia de entrada por emisora | **Verificada en vivo**: cambia el vúmetro y el stream sin reiniciar procesos ni cortar la emisión |
| Micrófono y reconexión por emisora | Persistencia y contrato de UI verificados |
| Monitor de señal (vista del oyente) | Verificado, y probado contra servidor real |
| Protección del mount ocupado | Verificado, incluida la petición `mode=delete` |
| **Runner Linux de Flutter** | **Añadido, compilado y ejecutado** |
| **Interfaz Flutter en Linux** | **Ejecutada y capturada en pantalla** |
| **Detección de dispositivos PulseAudio/PipeWire** | **Verificada con `pactl` real** |
| **Detección de dispositivos ALSA** | Parseo y comandos verificados; captura real con PCM `null` |
| **Selección automática pulse/alsa** | Verificada con las combinaciones posibles |
| **Códec MP3 / AAC-LC / AAC+** | MP3 y AAC-LC verificados con audio real; AAC+ requiere FFmpeg con `libfdk_aac` |
| **Entrada de audio por defecto** | **Predeterminado del sistema (default)** seleccionada |
| **Icono y lanzador** | Icono propio en Linux y Windows; scripts para `.desktop` y acceso directo |
| **Tipo de servidor** | El menu muestra solo **Icecast2** (sin nombres de hosting) |
| **Soundboard** | 8 pads, mezcla en vivo, cue local, ducking, loop y teclas 1-8 / F1-F8 |
| **Persistencia del soundboard** | `soundboard.json` + archivos en la carpeta de datos |
| **Cue local** | Linux por FFmpeg Pulse/ALSA; Windows por `ffplay.exe` |
| **Pruebas de widgets reales** | **22 pruebas con `flutter test`**: estados, colores, pulsaciones, ganancia en vivo, entrada sin preseleccionar, soundboard y desbordes de 900x600 a 1280x700 |
| Runner y captura de Windows | `.exe` compilado y arrancado en GitHub Actions; audio real pendiente |

### Comprobaciones ejecutables en cualquier momento

En Linux/macOS (con Flutter instalado y `PUB_CACHE` configurado). Si el SDK se
preparó con `tool/setup_local_sdk.sh`, ejecutar antes `source .tooling/env.sh`:

```bash
dart run tool/verify_core.dart              # 209 comprobaciones
dart run tool/verify_engine.dart            #  51 comprobaciones (FFmpeg simulado)
dart run tool/verify_ui.dart                #  20 comprobaciones
dart run tool/verify_signal.dart            #  25 comprobaciones
dart run tool/verify_occupied_mount.dart    #  14 comprobaciones
dart run tool/verify_server_detect.dart     #  18 comprobaciones
dart run tool/verify_widget_arguments.dart  #   3 comprobaciones
dart run tool/verify_ffmpeg_discovery.dart  #  21 comprobaciones
dart run tool/verify_linux_audio.dart       #  40 (audio REAL; ALSA opcional)
dart run tool/verify_soundboard.dart        #  25
dart run tool/verify_update.dart           #  29 (version, checksum y actualizador)

# Interfaz renderizada de verdad (no analisis estatico): 23 pruebas.
flutter test
```

`flutter test` monta la pantalla principal, Emisoras y Ajustes en un motor
Flutter real, a los tamanos de ventana de esta laptop (1280x687, 1000x620,
960x600 y 900x600). Falla si aparece un desborde, si el boton muestra el estado
equivocado o si el color de entrar/salir no corresponde.

En Windows los mismos comandos con `tool\...`. `verify_engine` necesita
`tools/fake_ffmpeg.exe`; en Linux/macOS, `tools/fake_ffmpeg` (se compila con
`cc -O2 -o tools/fake_ffmpeg tool/fake_ffmpeg.c`).

### Qué prueba exactamente la suite nueva

`verify_linux_audio` no usa el FFmpeg falso. Prueba dos caminos:

**PulseAudio/PipeWire:** crea un sink virtual con
`pactl load-module module-null-sink`, reproduce un tono de 1 kHz dentro de él,
captura su monitor con FFmpeg real y comprueba:

- que el proceso de captura arranca, que el mismo proceso sigue vivo al entrar
  al aire y que el MP3 llega al servidor;
- que el flujo contiene tramas MP3 válidas (incluida la etiqueta ID3v2 que
  antepone FFmpeg 7);
- que el vúmetro mide el tono real (≈ -6 dBFS);
- que la grabación local se escribe;
- que al salir del aire se detiene el codificador pero la captura sigue viva, y
  que al cerrar no queda ningún FFmpeg huérfano.

**Una sola captura y ganancia en vivo:** arranca la captura en modo vista previa,
comprueba que llegan niveles, aplica -12 dB y verifica que el vúmetro baja **sin
que cambie el PID de la captura**; al volver a 0 dB recupera el nivel. Con el
motor al aire repite el ajuste y comprueba que el PID de la captura y el del
codificador no cambian, que el audio sigue llegando al servidor y que no hay
ningún corte de captura.

**AAC-LC:** emite el mismo tono con el encoder nativo, comprueba cabecera ADTS
y que el `PUT` anuncia `audio/aac`.

**ALSA:** con `.tooling/ffmpeg-alsa/ffmpeg` o `ALSA_FFMPEG`, captura el PCM
`null` y comprueba que el flujo llega al servidor, que contiene tramas MP3, que
el vúmetro procesa el flujo dentro de rango y que el proceso se cierra. No mide
nivel porque el PCM `null` no garantiza silencio.

Al terminar desmonta el sink y mata el tono. Si no hay PulseAudio o FFmpeg con
soporte pulse, se **omite** con un mensaje claro: no falla por el entorno.

---

## Ronda 16: la interfaz, verificada de verdad

El analisis estatico (`verify_ui`) no ve desbordes ni colores. Esta ronda añade
`flutter test` con dos archivos:

- `test/broadcast_screen_test.dart` (13 pruebas): estado fuera del aire y al
  aire, texto y color del boton, cronometro, pulsacion real de los botones,
  ajuste de ganancia fuera y dentro del aire (aviso verde de "sin cortar la
  emision" y disparo del cambio al soltar el control), avisos de error y
  renderizado sin desbordes en 1280x700, 1280x687, 1000x620, 960x600 y 900x600.
- `test/other_screens_test.dart` (5 pruebas): Emisoras con y sin perfiles y
  Ajustes con dispositivos, en 1280x687 y 960x600.

Fallos que encontraron y se corrigieron:

1. **Ventana mas alta que la pantalla.** El runner pedia 1280x800 en un equipo
   de 1366x768: el pie quedaba fuera de alcance. Ahora toma el area util del
   monitor (`gdk_monitor_get_workarea`), deja 48 px de margen y fija un minimo
   de 960x600 sin superar nunca el tamano calculado.
2. **Señalizacion invertida.** Fuera del aire el boton era rojo con
   "SALIR AL AIRE"; al entrar quedaba rojo oscuro. Ahora es verde
   "ENTRAR AL AIRE" fuera y rojo "SALIR DEL AIRE" al aire, como una consola.
3. **Cabecera de Emisoras desbordada.** El texto y los botones compartian un
   `Row` sin `Expanded`: el parrafo empujaba los botones fuera de la ventana
   (desborde de mas de 1000 px). La descripcion ahora ocupa el espacio libre y
   envuelve; los botones quedan siempre visibles.
4. **Tarjetas de Ajustes sin Material.** Los `RadioListTile`/`SwitchListTile`
   estaban dentro de un `Container` con color; Flutter advierte que el toque no
   se ve. Las tarjetas ahora son `Material` con borde y recorte.

Ademas se probo el flujo completo con la interfaz real: perfil aislado en un
`HOME` temporal, servidor Icecast simulado, tono de 440 Hz en un sink virtual y
pulsaciones reales con XTest. El servidor recibio **713.874 bytes**, la pantalla
mostro "AL AIRE", 128 kbps reales y el vumetro; al pulsar "SALIR DEL AIRE" el
mount se libero y el monitor de entrada volvio a arrancar, sin FFmpeg huerfano.

**Nota de este equipo:** el driver DRI3 de esta laptop a veces no entrega
contexto GL. El proceso de la app sigue vivo pero la ventana queda sin mapear.
Se lanza entonces con `LIBGL_ALWAYS_SOFTWARE=1` y funciona con llvmpipe; no es
un fallo de Xtreme Studio. Con el compositor sano arranca con Impeller normal.

---

## Ronda 17: una sola captura de audio

La ronda 14 había resuelto el vúmetro fuera del aire con un **segundo** proceso
FFmpeg (`InputMonitor`) que solo medía. Funcionaba, pero tenía dos defectos que
se notaban en cabina:

1. **Había dos vúmetros en la práctica.** Fuera del aire medía un proceso y al
   entrar al aire otro, con otro dispositivo y otra latencia. Al cambiar de
   fuente el nivel podía saltar aunque el locutor no hubiera tocado nada.
2. **Mover la ganancia cortaba la emisión.** La ganancia era el filtro `volume`
   de FFmpeg; cambiarlo obliga a reiniciar el proceso de captura, y ese reinicio
   se oía como un corte y dejaba el vúmetro congelado un instante.

La arquitectura actual separa responsabilidades:

```
ffmpeg captura (dispositivo -> PCM f32le por stdout)
        |
        v
  motor en Dart: GainStage + LevelMeter   (una sola senal)
        |
        v
ffmpeg codificador (PCM f32le por stdin -> MP3/AAC por stdout)
        |
        v
  socket Icecast/Shoutcast + grabacion local
```

- `lib/core/audio/gain_stage.dart` aplica la ganancia sobre el PCM flotante. Es
  una multiplicación por bloque; cambiar `gainDb` afecta al bloque siguiente sin
  tocar procesos. Se usa `f32le` para conservar el excedente por encima de 0 dBFS
  y que el limitador del codificador decida cuánto recortar.
- `BroadcastEngine.startPreview()` mantiene la captura viva fuera del aire.
  `goLive()` reutiliza esa misma captura y solo agrega el codificador y el
  socket. `goOffAir()` detiene codificador y socket, no la captura.
  `dispose()` cierra todo.
- `LevelMeter.feedFloat()` mide el PCM **después** de la ganancia, exactamente lo
  que recibe el codificador. `clearHold()` se llama al mover la ganancia para que
  el número no muestre durante 2 s el nivel anterior.
- El codificador recibe `-probesize 32 -analyzeduration 0`. Sin eso FFmpeg
  analiza hasta 5 s de audio antes de emitir el primer paquete: con un flujo en
  vivo eso retrasa el arranque y, si el dispositivo entrega más lento que tiempo
  real, puede no emitir nada dentro de una prueba razonable.
- `setGain()` ya no reinicia la captura: solo cambia el factor, limpia el pico
  retenido y registra "sin cortar la emisión". La interfaz muestra ese mismo
  aviso en verde.

Pruebas que cubren el cambio:

- `verify_core` comprueba la línea de comandos de captura y codificador, que la
  ganancia **no** viaja como filtro `volume`, la aritmética de `GainStage`, los
  bloques partidos a mitad de muestra y el vúmetro sobre PCM flotante.
- `verify_engine` comprueba con FFmpeg simulado que al mover la ganancia cambian
  el vúmetro y los bytes enviados, pero **no** los PID de captura y codificador.
- `verify_linux_audio` comprueba lo mismo con audio real: fuera del aire,
  al aire y al salir (el codificador se detiene, la captura sigue).
- `verify_ffmpeg_discovery` y `verify_widget_arguments` verifican que los comandos
  mostrados en Ajustes corresponden a captura y codificador.

---

## Cómo se implementó el soporte Linux

### Capturador elegido, no asumido

`lib/core/audio/ffmpeg_capture.dart` ahora tiene un `CaptureBackend`
(`dshow`, `pulse`, `alsa`). `FfmpegLocator.resolveBackend()`:

1. en Windows devuelve `dshow`;
2. en Linux consulta `ffmpeg -devices`;
3. si trae `pulse`, comprueba `pactl info`; si el servidor no responde y
   también trae `alsa`, cae a ALSA;
4. si no trae `pulse` pero sí `alsa`, usa ALSA;
5. si no puede detectar nada, deja Pulse y explicará el error real.

El backend elegido se muestra en **Ajustes** y se usa para enumerar
dispositivos, para el comando copiable y para el diagnóstico de fallos. La
interfaz y el motor usan el mismo, así que no puede pasar que la lista muestre
un dispositivo Pulse y FFmpeg intente abrirlo por ALSA.

### Dispositivos

- **PulseAudio/PipeWire:** `pactl list sources` con `LANG=C` (las etiquetas
  traducidas harían frágil el parseo). Se incluyen los monitores
  (`*.monitor`), que permiten emitir lo que reproduce otro programa y probar
  sin micrófono. La descripción se muestra en español ("Monitor de ...").
- **ALSA:** `arecord -l` para tarjetas reales; si solo hay PCM virtuales, se usa
  `arecord -L` (por ejemplo `pipewire`, `plughw:0,0`). Se descartan `null` y el
  `default` duplicado.
- Siempre se ofrece una entrada `default`, válida en ambos sistemas.

### Diferencias de proceso

- `stop()` usa `taskkill` en Windows y `kill -9` por PID en Linux/macOS. Antes
  se llamaba a `taskkill` siempre y en Linux fallaba (quedaba un FFmpeg vivo
  ocupando el audio).
- El diagnóstico de fallos vuelve a abrir el **mismo** capturador y dispositivo
  (`args.inputArguments`), no `dshow` fijo.
- Los mensajes de error distinguen: build sin `pulse`/`alsa`, servidor Pulse
  caído, fuente inexistente, dispositivo ALSA ocupado, falta del plugin
  `alsa-plugins`, etc.

### Un fallo de concurrencia que salió al probar Linux

Al recoger la salida de un proceso se hacía `await exitCode` y enseguida
`cancel()` de la suscripción a `stderr`. Dart puede completar el código de salida
**antes** de entregar los últimos datos, así que el diagnóstico aparecía vacío
de forma intermitente. Ahora se espera al cierre del flujo
(`fold`/`transform(...).join()`). Afectaba a `version()`, `-devices`,
`pactl`/`arecord` y al diagnóstico de FFmpeg.

### Interfaz

- Se añadió el runner `linux/` con `flutter create --platforms=linux`.
- Ventana inicial adaptada al area util del monitor (maximo 1280x800, margen
  de 48 px, minimo 960x600), título "Xtreme Studio", fondo `#0D0F14`.
- **Ajustes** usa textos y rutas de Linux, abre el registro con `xdg-open`,
  muestra `pulse`/`alsa` y avisa de que en Linux no hay DPAPI (archivo `0600`).
- Se retiraron los textos que decían "Windows" en la lista de dispositivos.

### Compilación y empaquetado

```bash
tool/build_linux.sh
```

Comprueba `clang`, `cmake`, `ninja`, `pkg-config` y GTK 3 antes de compilar,
resuelve paquetes, compila en release y copia `ffmpeg`, la licencia,
`README.md` y `THIRD_PARTY.md` a:

```
build/linux/x64/release/bundle/
```

Si el SDK de Flutter está en un disco de solo lectura (el caso de este equipo),
`tool/setup_local_sdk.sh` copia SDK y caché a `.tooling/` (ignorado por git) y
genera `.tooling/env.sh`. No toca el HOME del usuario.

---

## Ronda 18: la emisión sobrevive al bloqueo de pantalla

Reporte del DJ en Linux: al dejar el equipo sin actividad, la pantalla se
bloqueaba y el audio de la app se detenía. Al desbloquear, la emisión seguía
"AL AIRE" pero muda.

**Causa.** En este equipo el escritorio es XFCE con `light-locker`. Al
bloquearse la pantalla, el bloqueador cambia a una sesión de *greeter* (otra VT).
La sesión del DJ pasa a inactiva, el grafo de PipeWire se rearma (se vio
`si-standard-link ... not valid anymore`, luego `pipewire-pulse: source not
ready`) y el FFmpeg de captura queda leyendo un nodo que ya no entrega audio.
El proceso no muere: se queda escribiendo PCM repetido y llenando el registro
con `non monotonically increasing dts`. La app no lo detectaba porque vigilaba
la **salida** del codificador, que seguía viva.

Se ataca por dos lados, porque ninguno basta solo:

1. **Evitar el disparador.** Mientras hay emisión, `lib/core/screen_guard.dart`
   pide al escritorio que no active el protector de pantalla. El detalle que
   costó una prueba: la inhibición por D-Bus está atada a la **conexión** que la
   pide, así que un `gdbus call ... Inhibit` suelto se pierde en cuanto el
   proceso termina (light-locker lo elimina al ver que el llamante se
   desconectó). Por eso se usan los comandos que se quedan vivos mientras dura
   la emisión: `light-locker-command --inhibit` (XFCE/light-locker, llama a
   `XScreenSaverSuspend`), `xfce4-screensaver-command --inhibit`,
   `kde-inhibit ...` o `gnome-session-inhibit ... sleep infinity`; el `gdbus`
   queda solo como último recurso. Además se bloquea la suspensión por
   inactividad con `systemd-inhibit --what=idle:sleep ... sleep infinity`. Al
   salir del aire se matan esos procesos y se suelta todo.
2. **Recuperarse si pasa igual.** El motor ahora marca `_lastPcmAt` con la
   **entrada** (no la salida). Si la captura deja de entregar PCM durante 4 s,
   o si el proceso de captura muere, se reabre **sin tocar el codificador ni el
   socket**: los oyentes no pierden el mount y el audio vuelve solo. Hay
   enfriamiento de 5 s entre reintentos por silencio, tope de 6, y si el proceso
   muere 4 veces en un minuto se sale del aire con el diagnóstico real (un
   dispositivo desenchufado no se arregla reintentando).

El ajuste vive en **Ajustes > Pantalla y suspensión** (solo Linux) y viene
activado. Se puede apagar si el DJ prefiere que la pantalla se bloquee; en ese
caso queda la recuperación automática de la captura. Se aplica al instante,
también con la emisión en curso.

Nota: en Windows el interruptor no se muestra porque no se reprodujo allí el
problema. Si apareciera, el reinicio automático de captura ya cubre el caso.

---

## Correcciones de la ronda 14 (lo que reportó el DJ)

La prueba con Zeno.fm destapó cuatro problemas reales:

1. **"Suena ahora" no cambiaba.** El cliente insertaba los metadatos
   (`StreamTitle=...`) dentro del flujo de audio con `icy-metaint`. Ese es el
   mecanismo de Shoutcast, **no** el de Icecast 2: Icecast espera una petición
   aparte a `/admin/metadata?mode=updinfo`. Los bytes de texto se estaban
   enviando como si fueran MP3, lo que además explica los **sonidos raros de
   fondo**. Ahora se envía la petición HTTP con las credenciales del mount (y
   las de administración como respaldo) y el audio va intacto.
2. **El nivel de entrada solo funcionaba al aire.** El motor no capturaba
   fuera de emisión. Se añadió `InputMonitor`, un FFmpeg liviano que solo mide
   PCM y mantiene el vúmetro activo siempre. **La ronda 17 lo reemplazó** por
   una sola captura reutilizada, para que el vúmetro no cambie de fuente al
   entrar al aire.
3. **La ganancia no se notaba.** Al no haber captura fuera del aire, el control
   no tenía efecto. Ahora la ganancia se aplica a la lectura del monitor y al
   filtro de FFmpeg al emitir. El número de pico se retiene 2 s para que no
   parpadee. **La ronda 17 la movió a Dart** para poder cambiarla sin reiniciar
   la captura.
4. **No se podía elegir códec/bitrate.** Se agregó `AudioCodec` (MP3, AAC-LC,
   AAC+), detección real con `ffmpeg -encoders`, selector por emisora y
   `Content-Type` correcto. La grabación usa el mismo códec/bitrate que el
   stream.

La sonda real contra Zeno.fm confirmó que `link.zeno.fm` y
`stream.zeno.fm:8000` aceptan `/admin/metadata` con las credenciales del mount
(HTTP 200) y que el título público no cambió cuando se reenvió el mismo título.

---

## Qué sigue bloqueado

1. **El audio real en Windows no se ha probado.** El `.exe` compila y arranca
   en GitHub Actions (run `42753682644`), y `verify_core` pasa 210
   comprobaciones en Windows, pero el runner no tiene micrófono. Falta abrir la
   app en una PC Windows con el micrófono/consola real y probar dshow, vúmetro,
   ganancia y emisión.
2. **La captura real por ALSA no se ha probado contra hardware.** Se verificó
   con el PCM `null` de ALSA (silencio/datos del plugin, no audio de una
   tarjeta). En este equipo el audio lo administra PipeWire y falta el plugin
   `libasound_module_pcm_pipewire.so`, así que no hay una tarjeta ALSA libre.
   La app elige y construye ALSA correctamente (probado), pero la prueba con un
   dispositivo ALSA real queda pendiente.
3. **No se ha probado un micrófono real.** La captura real se hizo con un sink
   virtual y un tono. Eso valida FFmpeg, PulseAudio, el motor, los vúmetros y la
   grabación, pero no el driver del micrófono ni el nivel de entrada de una
   consola.
4. **AAC+ no se pudo probar en este equipo.** El FFmpeg incluido en `tools/`
   no trae `libfdk_aac` (la build GPL de BtbN lo excluye). El código y la
   detección están listos, y la opción aparece como "no disponible". Para
   usarla hay que apuntar la app a un FFmpeg compilado con
   `--enable-libfdk-aac --enable-nonfree`.
5. **No se ha emitido contra la radio real del usuario (Zeno.fm).** Sigue en
   pie el aviso de la sección siguiente. Solo se hizo la sonda de metadatos con
   el mismo título, para no desplazar al DJ ni cambiar la programación.

### Build verificado en GitHub Actions

- Run: `42753682644` (workflow `Windows build`, `windows-latest`).
- Flutter 3.47.8, MSVC/CMake/Windows SDK, FFmpeg GPL win64 descargado por el
  workflow.
- `verify_core`: **210 comprobaciones en verde**.
- `verify_soundboard`: **18**; `verify_update`: **29**.
- `flutter build windows --release`: `xtreme_studio.exe` generado, version 0.1.1.
- Arranque comprobado por el script: `[ok] La aplicacion arranco correctamente`.
- Release publicada: `v0.1.1`.
- ZIP: `XtremeStudio-0.1.1-windows-x64.zip` (149.977.121 bytes,
  SHA-256 `5cbeaa40daa2e92b19fb696749854ee09ca9b7908efcb1cb4ba2d0fc3c07d023`).
- Incluye `checksums.txt`, `ffmpeg.exe` y `ffplay.exe`.
- Icono incrustado verificado: `[ok] Icono del ejecutable: 32x32`.

### Pasos para la prueba final en Windows

Los scripts ya no tienen rutas fijas: usan la raiz del proyecto y buscan
Flutter en el `PATH`, en `FLUTTER_BIN` o en las rutas tipicas.

```powershell
cd <ruta-del-proyecto>

# 1. Comprobar que el equipo puede compilar (no compila nada, tarda segundos)
powershell -ExecutionPolicy Bypass -File tool\check_toolchain.ps1

# 2. Poner FFmpeg en su sitio
#    Descargar una build "full" o "gpl" de https://www.gyan.dev/ffmpeg/builds/
#    y copiar ffmpeg.exe a  <ruta-del-proyecto>\tools\

# 3. Compilar
powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1

# 4. Compilar el FFmpeg falso y probar el motor
powershell -ExecutionPolicy Bypass -File tool\build_fake_ffmpeg.ps1
dart run tool\verify_engine.dart
```

Si no hay una PC Windows, `.github/workflows/windows.yml` compila en GitHub
Actions y publica la carpeta `Release` como artifact. Ese camino ya se ejecutó
con éxito en el run `42753682644`.

Salida esperada: `build\windows\x64\runner\Release\xtreme_studio.exe`, con
`ffmpeg.exe`, la licencia y la documentación copiadas al lado.

### Prueba en Linux sin radio real

```bash
dart run tool/demo_icecast.dart 18000 /demo
```

Crear una emisora con host `127.0.0.1`, puerto `18000`, mount `/demo`, usuario
`source` y cualquier clave. El servidor responde al monitor de señal como un
oyente. Para ver los vúmetros sin micrófono, elegir en Ajustes el monitor de un
sink de PipeWire/PulseAudio y reproducir algo en él.

---

## Prueba en vivo: leer antes de intentarla

El servidor de prueba del usuario es **Zeno.fm**:

- Host de **escucha**: `link.zeno.fm` (redirige al CDN)
- Host de **publicación**: `stream.zeno.fm:8000`
- Mount: `/5tmrzbywtzzuv`
- Clave: **se retiró de este documento**. Estaba escrita en claro en el
  repositorio; conviene rotarla en el panel de Zeno.fm. La sonda la lee de la
  variable de entorno `XTREME_PROBE_PASS`.
- Estado verificado por sondas anteriores: al aire con "LatinSound 507".

> **Antes de emitir en ese mount, confirmar que la cabina está libre.** Conectar
> una fuente ahí desplaza a quien esté transmitiendo.

Notas importantes de ese hosting, medidas con sondas reales:

1. **`stream.zeno.fm:8000` acepta el handshake con credenciales válidas.** El
   mount efectivo puede ser `/5tmrzbywtzzuv` o `/5tmrzbywtzzuv/source`; ambos
   respondieron igual. Confirmar con un mount libre antes de la prueba final.
2. **Zeno.fm rechaza `HEAD` con 405** pero sirve el audio con `GET`. Por eso el
   monitor de señal usa `GET` (ver `stream_health.dart`); cambiarlo a `HEAD`
   rompe la comprobación.
3. **Zeno.fm no devuelve 403 cuando el mount está ocupado**: el handshake se
   acepta siempre. La protección del mount ocupado **no actúa** en ese hosting.
   Hay que coordinarlo a mano.

Sondas disponibles (ambas de solo lectura, no desplazan a nadie):

```bash
# La clave se pasa por entorno, nunca se escribe en el archivo.
XTREME_PROBE_HOST=stream.zeno.fm \
XTREME_PROBE_MOUNT=/5tmrzbywtzzuv \
XTREME_PROBE_USER=source \
XTREME_PROBE_PASS=... \
dart run tool/probe_icecast.dart

dart run tool/probe_signal.dart    # comprueba que el mount se sirve
```

---

## Qué queda pendiente de funcionalidad

Del plan original, sin empezar:

- **Monitoreo completo** de la mezcla por auriculares. El soundboard fase 1 ya
  mezcla jingles y tiene cue local, pero el cue reproduce el jingle, no la
  mezcla completa con el micrófono.
- **API de administración** de AzuraCast/Icecast (expulsar a un DJ, consultar
  quién está al aire). Las credenciales `adminUsername`/`adminPassword` se usan
  solo como respaldo para actualizar el título, y todavía no hay controles en la
  interfaz para cargarlas.
- **Notificaciones push** y **panel web** de la fase 3 del plan.

Nada de esto está a medias: simplemente no se empezó.

---

## Archivos que cambiaron

Ronda 13 (soporte Linux):

- `linux/` — runner Linux completo (CMake, GTK, ventana).
- `lib/core/audio/ffmpeg_capture.dart` — backend pulse/alsa, enumeración Linux,
  parada multiplataforma, errores Linux, corrección de concurrencia al leer
  procesos.
- `lib/core/audio/broadcast_engine.dart` — resuelve y propaga el backend,
  diagnóstico con el backend correcto.
- `lib/main.dart` — resuelve backend junto con la lista de dispositivos y lo
  pasa al motor y a Ajustes.
- `lib/ui/settings_screen.dart` — textos/rutas Linux, abrir registro,
  privacidad, comando con el backend real.
- `tool/build_linux.sh`, `tool/setup_local_sdk.sh`, `tool/demo_icecast.dart`.

Ronda 14 (correcciones reportadas por el DJ):

- `lib/core/net/icecast_client.dart` — metadatos por `/admin/metadata`; se
  eliminó el entrelazado `icy-metaint` que corrompía el audio.
- `lib/core/audio/input_monitor.dart` — monitor de entrada permanente
  (**eliminado en la ronda 17**: la captura del motor cumple esa función).
- `lib/core/audio/ffmpeg_capture.dart` — modo `meterOnly`, pico retenido,
  códecs MP3/AAC/AAC+, detección de encoders y flujo MP3 sin ID3/Xing.
- `lib/core/audio/broadcast_engine.dart` — códec en captura, extensión de
  grabación según códec, `setTrack` devuelve si el servidor aceptó.
- `lib/core/server_profile.dart` — `AudioCodec`, `AudioSettings.codec` y
  validación por códec.
- `lib/main.dart` — arranque del monitor al inicio, parada al salir al aire,
  reactivación al volver, ganancia en el vúmetro y avisos del título.
- `lib/ui/broadcast_screen.dart`, `lib/ui/widgets/vu_meter.dart` — pico retenido
  y mensaje "Los oyentes ven...".
- `lib/ui/profiles_screen.dart` — selector de códec/bitrate y aviso de AAC+.
- `lib/ui/settings_screen.dart` — nota de calidad de grabación y textos Linux.
- `tool/verify_core.dart`, `tool/verify_engine.dart`,
  `tool/verify_linux_audio.dart`, `tool/demo_icecast.dart` — pruebas y servidor
  local adaptados a metadatos fuera del flujo y a códecs.
- `tool/probe_asura.dart` — se quitaron credenciales en claro y `icy-metaint`.
- `README.md`, `ESTADO.md`, `THIRD_PARTY.md`, `docs/screenshots/`.

Ronda 17 (una sola captura):

- `lib/core/audio/gain_stage.dart` — **nuevo**: ganancia lineal sobre PCM
  `f32le`, con reensamblado de bloques partidos a mitad de muestra.
- `lib/core/audio/ffmpeg_capture.dart` — `CaptureArgs` (solo captura, PCM por
  stdout), `EncoderArgs` (PCM por stdin, limitador, `-probesize`/
  `-analyzeduration` mínimos), `FfmpegProcess` con roles, `LevelMeter.feedFloat`
  y `clearHold`.
- `lib/core/audio/broadcast_engine.dart` — captura única, `startPreview`,
  `_onPcm`, `_startEncoder`/`_stopEncoder`, `setGain` en vivo y limpieza.
- `lib/main.dart` — un solo `_snapshot`, `_prepareEngine`, `_startPreview`, sin
  `InputMonitor`.
- `lib/ui/broadcast_screen.dart` — aviso verde de ajuste en vivo sin corte.
- `lib/ui/settings_screen.dart` — muestra los comandos de captura y codificador.
- `tool/fake_ffmpeg.c` y `tools/fake_ffmpeg` — doble de FFmpeg para ambos roles.
- `tool/verify_core.dart`, `tool/verify_engine.dart`, `tool/verify_linux_audio.dart`
  y `tool/verify_ffmpeg_discovery.dart` — pruebas de la nueva arquitectura.

Ronda 18 (bloqueo de pantalla):

- `lib/core/screen_guard.dart` — **nuevo**: inhibe el bloqueo de pantalla con
  `light-locker-command --inhibit` (o `xfce4-screensaver-command`,
  `kde-inhibit`, `gnome-session-inhibit`, con `gdbus` de último recurso) y la
  suspensión con `systemd-inhibit`; nunca lanza si el escritorio no lo soporta.
- `lib/core/audio/broadcast_engine.dart` — `keepScreenAwake` (getter/setter),
  `_recoverCapture`, marcas `_lastPcmAt`/`_captureStartedAt`, límites de
  reintento y `_handleCaptureFailure` con motivo.
- `lib/core/profile_store.dart` — `AppSettings.keepAwakeWhileLive` (activado de
  fábrica) persistido en `settings.json`.
- `lib/main.dart` — pasa el ajuste al motor y lo actualiza en caliente.
- `lib/ui/settings_screen.dart` — tarjeta "Pantalla y suspensión" (solo Linux).
- `tool/verify_core.dart`, `tool/verify_engine.dart` — cookie de D-Bus,
  persistencia del ajuste y reapertura de captura sin cortar la emisión.
- `tool/verify_linux_audio.dart` — las pruebas no inhiben la pantalla.
