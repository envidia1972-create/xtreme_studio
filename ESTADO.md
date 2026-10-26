# Estado del proyecto y qué falta

Documento de relevo. Existe porque el trabajo se detuvo en un punto concreto y
quien lo retome (o el propio autor dentro de un mes) necesita saber **exactamente
dónde está el corte** sin reconstruirlo desde cero.

Fecha del corte: **ronda 16 (interfaz verificada con pruebas de widgets)**.
Última verificación: **335 comprobaciones automáticas en Linux** (nueve
suites), **16 pruebas de widgets** (`flutter test`) y **172 en Windows**
(`verify_core`), con el `.exe` compilado y arrancado en GitHub Actions. La
interfaz Flutter se ejecutó de verdad, con runner Linux, capturó audio real por
PulseAudio/PipeWire y emitió contra un servidor Icecast simulado.

En esta ronda se corrigieron fallos que solo aparecían al renderizar de verdad:
la ventana pedía 1280x800 y se salía de una pantalla de 1366x768, el botón de
entrar al aire era rojo (parecía "detener"), la cabecera de Emisoras desbordaba
a la derecha y las tarjetas de Ajustes no daban respuesta visual al tocar.

Capturas de esa ejecución: `docs/screenshots/linux-nivel-idle.png`,
`docs/screenshots/linux-al-aire.png`, `docs/screenshots/linux-codecs.png`,
`docs/screenshots/linux-emisoras.png` y `docs/screenshots/linux-ajustes.png`.
Las de esta ronda se tomaron en un portátil de 1366x768: la ventana se ajusta al
área útil y se ve completa.

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
| Captura y codificación MP3 por FFmpeg | **Verificada con audio real en Linux** |
| Motor de emisión, reconexión y detección de caída | Verificado con FFmpeg simulado y con audio real |
| Red estancada (backpressure) y conexión “zombi” | Verificado con servidor que deja de leer |
| TLS con certificado autofirmado | Verificado con certificado real embebido |
| Metadatos por `/admin/metadata` (Icecast/Zeno.fm) | Verificado con servidor simulado y sonda real |
| Vúmetros de pico y RMS, siempre activos | Verificado con ondas sintéticas y con audio real, fuera y dentro del aire |
| Grabación local | Verificada con audio real; usa el mismo codec/bitrate que el stream |
| Ganancia de entrada por emisora | Verificada en el vúmetro y en el audio real |
| Micrófono y reconexión por emisora | Persistencia y contrato de UI verificados |
| Monitor de señal (vista del oyente) | Verificado, y probado contra servidor real |
| Protección del mount ocupado | Verificado, incluida la petición `mode=delete` |
| **Runner Linux de Flutter** | **Añadido, compilado y ejecutado** |
| **Interfaz Flutter en Linux** | **Ejecutada y capturada en pantalla** |
| **Detección de dispositivos PulseAudio/PipeWire** | **Verificada con `pactl` real** |
| **Detección de dispositivos ALSA** | Parseo y comandos verificados; captura real con PCM `null` |
| **Selección automática pulse/alsa** | Verificada con las combinaciones posibles |
| **Códec MP3 / AAC-LC / AAC+** | MP3 y AAC-LC verificados con audio real; AAC+ requiere FFmpeg con `libfdk_aac` |
| **Pruebas de widgets reales** | **16 pruebas con `flutter test`**: estados, colores, pulsaciones y ausencia de desbordes de 900x600 a 1280x700 |
| Runner y captura de Windows | `.exe` compilado y arrancado en GitHub Actions; audio real pendiente |

### Comprobaciones ejecutables en cualquier momento

En Linux/macOS (con Flutter instalado y `PUB_CACHE` configurado). Si el SDK se
preparó con `tool/setup_local_sdk.sh`, ejecutar antes `source .tooling/env.sh`:

```bash
dart run tool/verify_core.dart              # 171 comprobaciones
dart run tool/verify_engine.dart            #  37 comprobaciones (FFmpeg simulado)
dart run tool/verify_ui.dart                #  20 comprobaciones
dart run tool/verify_signal.dart            #  23 comprobaciones
dart run tool/verify_occupied_mount.dart    #  14 comprobaciones
dart run tool/verify_server_detect.dart     #  15 comprobaciones
dart run tool/verify_widget_arguments.dart  #   3 comprobaciones
dart run tool/verify_ffmpeg_discovery.dart  #  20 comprobaciones
dart run tool/verify_linux_audio.dart       #  32 (audio REAL; ALSA opcional)

# Interfaz renderizada de verdad (no analisis estatico): 16 pruebas.
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

- que el proceso de captura arranca y el MP3 llega al servidor;
- que el flujo contiene tramas MP3 válidas (incluida la etiqueta ID3v2 que
  antepone FFmpeg 7);
- que el vúmetro mide el tono real (≈ -6 dBFS);
- que la grabación local se escribe;
- que al salir del aire no queda ningún FFmpeg huérfano.

**Monitor de entrada:** arranca el monitor con el tono, verifica que llegan
niveles fuera del aire y que una ganancia de -12 dB baja de verdad el nivel
medido. Tambien comprueba la ganancia en caliente mientras se emite.

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

- `test/broadcast_screen_test.dart` (11 pruebas): estado fuera del aire y al
  aire, texto y color del boton, cronometro, pulsacion real de los botones,
  avisos de error y renderizado sin desbordes en 1280x700, 1280x687, 1000x620,
  960x600 y 900x600.
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
   PCM y mantiene el vúmetro activo siempre.
3. **La ganancia no se notaba.** Al no haber captura fuera del aire, el control
   no tenía efecto. Ahora la ganancia se aplica a la lectura del monitor y al
   filtro de FFmpeg al emitir. El número de pico se retiene 2 s para que no
   parpadee.
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
   en GitHub Actions (run `40232577146`), y `verify_core` pasa 172
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

- Run: `40232577146` (workflow `Windows build`, `windows-latest`).
- Flutter 3.47.8, MSVC/CMake/Windows SDK, FFmpeg GPL win64 descargado por el
  workflow.
- `verify_core`: **172 comprobaciones en verde**.
- `flutter build windows --release`: `xtreme_studio.exe` generado en 56,7 s.
- Arranque comprobado por el script: `[ok] La aplicacion arranco correctamente`.
- Artifact: `xtreme_studio-windows-x64` (14 archivos, 79,5 MB con FFmpeg).

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
con éxito en el run `40232577146`.

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

- **Soundboard** con teclas rápidas (jingles, cortinas). Requiere mezclar audio
  en vivo, que hoy no está implementado: la app captura, codifica y envía, pero
  no mezcla dos fuentes.
- **Escuchar la propia señal** (monitoreo). Se retiró el ajuste porque nunca se
  implementó; requeriría decodificar el MP3 de salida.
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
- `lib/core/audio/input_monitor.dart` — monitor de entrada permanente.
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
