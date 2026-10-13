# Xtreme Studio

Consola de emision **multi-emisora** para radio, estilo BUTT pero con marca
propia: cada DJ carga las credenciales de **su** servidor (el tuyo o el de
cualquier otra emisora, en cualquier hosting). El audio sale directo de la PC del
locutor al servidor de streaming: no pasa por ningun servidor intermedio nuestro.

> **Estado:** nucleo completo y verificado (**176 comprobaciones automaticas**
> repartidas en cinco suites), mas una prueba de integracion del motor de
> emision lista para correr. Falta compilar el ejecutable de Windows, que debe
> hacerse desde una terminal normal (ver *Compilar*), porque el entorno donde se
> desarrollo la app bloquea el lanzamiento de subprocesos, y tanto
> `flutter build` como FFmpeg los necesitan.
>
> **Si retomas este proyecto, lee `ESTADO.md`**: ahi esta el punto exacto donde
> se detuvo el trabajo, los dos bloqueos medidos y los dos pasos que faltan.

---

## Que hace hoy

| Funcion | Estado |
|---|---|
| Gestor de emisoras: crear, editar, duplicar, borrar | Listo |
| Protocolos **Icecast 2**, **Shoutcast v1** y **v2** | Listo |
| Credenciales cifradas con **DPAPI** (atadas al usuario de Windows) | Listo |
| Boton **PROBAR CONEXION** con diagnostico legible (401, 403, 404...) | Listo |
| **SALIR AL AIRE / SALIR** en un clic | Listo |
| Vumetros de pico y RMS con escala en dBFS | Listo |
| Campo **"suena ahora"** con metadatos en vivo | Listo |
| **Ganancia de entrada** ajustable y guardada por emisora | Listo |
| **Reconexion automatica** con espera creciente | Listo |
| **Reconexion desactivable por emisora** | Listo |
| **Deteccion de caida del servidor** a mitad de emision | Listo |
| **Proteccion contra desplazar a otro DJ** (avisa antes de forzar) | Listo |
| **Comprobacion de la senal publicada** (vista del oyente) | Listo |
| Grabacion local de la emision | Listo |
| Registro de actividad en pantalla | Listo |
| Importar / exportar perfil **sin** contrasena | Listo |
| Soundboard, notificaciones push, panel web | Pendiente (fases siguientes) |

---

## Como funciona (y por que asi)

```
  microfono / linea
         |
    [ FFmpeg ]  captura (dshow/WASAPI) y codifica a MP3
         |  stdout
    [ motor en Dart ]  -- socket -->  Icecast / Shoutcast
         |  stderr (PCM)
    [ vumetros en pantalla ]
```

Tres decisiones que marcan la diferencia frente a "dejar que FFmpeg haga todo":

1. **El socket lo maneja la app, no FFmpeg.** Por eso funciona con Shoutcast
   v1/v2 (que necesitan un *handshake* que `-f mp3` no negocia) y por eso
   podemos leer el codigo HTTP real y decir *"la contrasena fue rechazada"* en
   lugar de un error generico.
2. **La captura nunca se reinicia.** Si se cae la red, solo se rehace el socket.
   El DJ no tiene que volver a elegir el microfono y la grabacion no se corta.
3. **Metadatos se insertan en el propio flujo (`icy-metaint`).** El "suena
   ahora" cambia en el siguiente limite de bloque, sin reconectar.
4. **La app pregunta lo mismo que un oyente.** Cada 30 segundos, mientras esta
   al aire, pide la URL de escucha y verifica que el servidor responda con
   audio. Que nuestro socket siga abierto no garantiza que el mount se este
   sirviendo: el servidor puede aceptar la conexion y no publicar la fuente.
   En ese caso el DJ veria "AL AIRE" sin que nadie lo escuche.

   Detalle importante: esa comprobacion usa `GET`, no `HEAD`. Hostings como
   Zeno.fm **rechazan `HEAD` con 405** aunque sirvan el audio perfectamente, asi
   que con `HEAD` el monitor daria falsos avisos justo en los servidores mas
   usados. Se lee solo la cabecera de respuesta y se cierra la conexion.

---

## Compilar

Requisitos ya verificados en este equipo:

- Flutter 3.47.1 (stable) en `C:\Users\Usuario\flutter`
- Visual Studio Build Tools 2026, con MSVC 14.50, CMake y Windows SDK 10.0.26100
- FFmpeg **no** esta instalado todavia (ver abajo)

Primero, comprobar que no falta nada (tarda unos segundos y no compila):

```powershell
cd C:\Desarrollo\xtreme_studio
powershell -ExecutionPolicy Bypass -File tool\check_toolchain.ps1
```

Luego compilar:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1
```

El script comprueba Flutter, MSVC, CMake y el Windows SDK **antes** de empezar
(para no fallar tras varios minutos), resuelve dependencias y deja el ejecutable
en:

```
build\windows\x64\runner\Release\xtreme_studio.exe
```

Tambien copia `ffmpeg.exe`, su licencia, el `README.md` y `THIRD_PARTY.md`
dentro de esa carpeta, que es la que se entrega a otra emisora.

### FFmpeg

Es la unica pieza externa que la app necesita (captura + codificacion MP3).
Descarga una build **full** o **gpl** desde <https://www.gyan.dev/ffmpeg/builds/>
y copia `ffmpeg.exe` a la carpeta `tools\` del proyecto; el script lo copiara
solo junto al ejecutable. Tambien podes indicar la ruta desde **Ajustes** dentro
de la app.

> Nota: en el equipo de desarrollo no se pudo descargar FFmpeg porque el
> protocolo TLS del sistema esta roto (`Schannel: SEC_E_NO_CREDENTIALS`), lo que
> afecta a cualquier descarga HTTPS. Se resuelve reinstalando el proveedor de
> cifrado de Windows o descargando el archivo desde otro equipo.

---

## Verificar el nucleo (sin compilar)

No necesitan Flutter ni internet: levantan un **servidor Icecast simulado** en
memoria y comprueban el comportamiento real del protocolo.

```powershell
$env:APPDATA = 'C:\Desarrollo\xtreme_studio\.tmp_appdata'
$env:PUB_CACHE = 'C:\Desarrollo\xtreme_studio\.pubcache'
dart run tool\verify_core.dart             # 103 comprobaciones
dart run tool\verify_ui.dart               # 18 comprobaciones
dart run tool\verify_ffmpeg_discovery.dart # 18 comprobaciones
dart run tool\verify_signal.dart           # 23 comprobaciones
dart run tool\verify_occupied_mount.dart   # 14 comprobaciones
dart run tool\verify_engine.dart           # motor completo (necesita lanzar procesos)
```

`verify_core` cubre: peticion HTTP de Icecast, handshake 100/401/403/404,
entrelazado de metadatos (parseado igual que un reproductor), Shoutcast v1/v2,
vumetros, linea de comandos de FFmpeg, cifrado DPAPI y persistencia (incluida la
comprobacion de que **la contrasena nunca queda en texto plano en disco**).

`verify_ffmpeg_discovery` comprueba donde busca FFmpeg la app: junto al
ejecutable, en la carpeta `tools\` del proyecto y subiendo por los directorios
padre, mas las ubicaciones tipicas de winget, Chocolatey y Scoop. Tambien revisa
que el comando de captura quede bien citado (nombres de dispositivo con espacios
y parentesis) y que los mensajes de error de FFmpeg sean entendibles.

`verify_ui` incluye dos comprobaciones de **fallos que solo aparecen al
ejecutar** y que ni el compilador ni el analizador detectan:

- **`setState` despues de un `await` sin comprobar `mounted`**: lanza excepcion
  si el DJ cambia de pantalla mientras algo esta cargando. El analisis compara
  profundidades de llaves para no mezclar metodos ni callbacks (que es lo que
  produce falsos positivos).
- **Temporizadores que no se cancelan** en `dispose`: dejan trabajo corriendo
  despues de cerrar una pantalla.

Ambas se validaron **inyectando un bug a proposito** en el codigo y comprobando
que la suite falla senalando la linea exacta; un verificador que nunca falla no
sirve de nada.

`verify_engine` es la prueba mas completa: reemplaza FFmpeg por
`tools\fake_ffmpeg.exe` (un doble que emite MP3 por stdout y PCM por stderr
igual que el real, ver `tool\fake_ffmpeg.c`) y verifica la cadena entera:
arranque, argumentos con los que se invoca a FFmpeg, llegada de audio al
servidor con cabecera MP3 valida, vumetros midiendo -6 dBFS, metadatos en el
flujo, grabacion local identica a lo enviado, **caida de red y reconexion
automatica**, y apagado sin dejar procesos huerfanos.

> Esa prueba **necesita poder lanzar procesos**, asi que debe correrse en una
> terminal normal. Si se ejecuta dentro de un entorno restringido, avisa y se
> detiene en lugar de fallar de forma confusa.

### Un detalle del motor que conviene conocer

FFmpeg escribe **dos cosas distintas por la misma salida de error**: el PCM
crudo que alimenta los vumetros y sus propios mensajes de log. La app los
separa (`looksLikeText` en `ffmpeg_capture.dart`) y usa los mensajes para poder
explicar un fallo real ("otro programa esta usando el microfono") en lugar de un
"FFmpeg termino" sin motivo.

La separacion es una heuristica: un bloque que contenga algun byte binario se
trata como audio. En el peor caso imaginable (un bloque de audio formado
integramente por bytes ASCII imprimibles) se descartaria **solo para el
vumetro**, durante un fotograma; el audio que reciben los oyentes viaja por otra
tuberia y no se ve afectado.

### Cuando la captura muere, la app averigua por que

Los mensajes de FFmpeg no siempre alcanzan a llegar antes de que el proceso
muera, asi que el motor no se conforma con un "termino sin explicar el motivo":
si los mensajes recogidos no explican nada, **relanza FFmpeg pidiendo solo 0,2
segundos de audio** sobre el mismo dispositivo. En esa ejecucion corta la salida
de error esta libre y FFmpeg escribe el motivo real ("Could not find audio only
device", "Access is denied"). Ese texto se traduce a una indicacion concreta
para el DJ: que otro programa ocupa el microfono, o que el dispositivo elegido
ya no existe.

La prueba de integracion del motor cubre ese camino: el `ffmpeg` falso devuelve
un mensaje real cuando se lo invoca en modo diagnostico, y se comprueba que el
mensaje final al DJ explica la causa en vez de caer en el texto generico.

### Sonda contra un servidor real

```powershell
dart run tool\probe_icecast.dart   # handshake de publicacion (no envia audio)
dart run tool\probe_signal.dart    # comprobacion de escucha (solo lectura)
```

`probe_icecast` hace *solo* el handshake (`Expect: 100-continue`), sin enviar
audio, para descubrir el endpoint de ingesta correcto y validar las credenciales
sin cortar una emision que este al aire.

`probe_signal` pregunta por el mount como lo haria un reproductor y descarta el
cuerpo: sirve para saber si la emisora esta siendo servida, **sin desplazar a
ningun DJ**.

---

## Estructura

```
lib/
  core/
    server_profile.dart      Modelo de emisora (protocolo, calidad, metadatos)
    secret_store.dart        Cifrado DPAPI via FFI (CryptProtectData)
    profile_store.dart       Persistencia en %APPDATA%\XtremeStudio
    net/
      icecast_client.dart    Cliente Icecast 2 + metadatos icy-metaint
      shoutcast_client.dart  Cliente Shoutcast v1/v2 (handshake propio)
      broadcaster.dart       Fachada + "probar conexion"
      stream_health.dart     Comprueba la senal como la ve un oyente
    audio/
      ffmpeg_capture.dart    Argumentos de captura, dispositivos, vumetros
      broadcast_engine.dart  Maquina de estados + reconexion
  ui/
    theme.dart               Paleta pensada para cabina
    broadcast_screen.dart    Pantalla principal (SALIR AL AIRE)
    profiles_screen.dart     Gestor de emisoras
    settings_screen.dart     FFmpeg, dispositivo, grabacion
    widgets/vu_meter.dart    Vumetro dibujado a mano
tool/
  check_toolchain.ps1       Comprueba que el equipo puede compilar (no compila)
  build_windows.ps1          Compilacion asistida
  setup_local_sdk.ps1        SDK de Flutter local (por si el SDK real queda en solo lectura)
  verify_core.dart           Verificacion del nucleo (103 comprobaciones)
  verify_ui.dart             Verificacion de la interfaz (18 comprobaciones)
  verify_ffmpeg_discovery.dart  Deteccion de FFmpeg (18 comprobaciones)
  verify_signal.dart         Monitor de senal (23 comprobaciones)
  verify_occupied_mount.dart Proteccion del mount ocupado (14 comprobaciones)
  verify_engine.dart         Integracion del motor de emision
  probe_icecast.dart         Sonda de handshake contra un servidor real
  probe_signal.dart          Sonda de senal (solo lectura) contra un servidor real
  fake_ffmpeg.c              FFmpeg falso para las pruebas del motor
```

---

## Si el audio no sale

Tres comprobaciones, en orden:

1. **FFmpeg detectado.** En *Ajustes* debe aparecer su version. Si no, pega la
   ruta completa a `ffmpeg.exe` y pulsa *Comprobar*; el boton **Autodetectar**
   busca junto al ejecutable, en `tools\`, subiendo por los directorios padre y
   en las instalaciones de winget, Chocolatey y Scoop.
2. **El comando exacto.** En *Ajustes*, desplega *Ver el comando de FFmpeg* y
   pegalo en una consola. Ahi aparece el error real de FFmpeg, que es lo unico
   que permite distinguir entre "el microfono esta ocupado", "el dispositivo no
   existe" y "la salida esta mal armada".
3. **Probar conexion.** En *Mis emisoras*, el boton de antena valida las
   credenciales sin enviar audio. Si el servidor responde 401, el problema son
   las credenciales; si responde 403, ya hay otro DJ en ese mount.

---

## Varios locutores, una sola clave

Este es el caso que hace distinto al Modo B frente a emisores de un solo
usuario, y el mas facil de arruinar: si varios DJs de la misma emisora comparten
la clave del mount, cualquiera puede entrar mientras otro esta al aire.

Icecast responde **403** y SHOUTcast **409** cuando el punto de montaje ya tiene
una fuente. La app reconoce ese codigo y **no entra sin preguntar**: muestra un
aviso que explica la consecuencia real ("el otro locutor sale sin aviso y sus
oyentes pasan a escucharte a vos") y ofrece esperar o continuar.

Si el DJ confirma, la app no se limita a insistir: pide al servidor que **libere
la fuente actual** (`?mode=delete` en Icecast) y recien entonces reintenta. Asi
el cambio es inmediato en lugar de esperar a que el servidor expire la sesion
anterior por timeout.

> Limite honesto: algunos hosting **no** devuelven ese codigo y simplemente
> desplazan a la fuente anterior. En ese caso no hay nada que detectar desde el
> lado del cliente, y la app no puede proteger de eso. Con Zeno.fm, por ejemplo,
> el handshake se acepta siempre, asi que la proteccion no actua: la
> coordinacion entre locutores sigue siendo necesaria.

---

## Seguridad

- Las contrasenas **nunca** se guardan en `profiles.json`. Van a
  `secrets\<id>.bin`, cifradas con DPAPI y atadas al usuario de Windows: copiar
  ese archivo a otra PC no revela nada.
- Al **exportar** un perfil la contrasena no se incluye, ni siquiera cifrada:
  el receptor tiene que escribirla.
- La entropia adicional de DPAPI incluye un identificador de la aplicacion, de
  modo que otro programa del mismo usuario no puede descifrar nuestras claves
  sin conocerla.
- La app **no** envia audio ni credenciales a ningun servidor propio: no hay
  backend.

---

## Prueba en vivo (importante)

El servidor de prueba del usuario (`stream.zeno.fm`, mount `5tmrzbywtzzuv`)
**esta al aire ahora mismo** con la emisora *"LatinSound 507"* (audio AAC). Un
cliente nuevo que se conecte a ese mismo mount **desplaza al DJ que esta
transmitiendo**.

Por eso la prueba real debe hacerse cuando la cabina este libre, o creando otro
mount/clave en el panel de Zeno.fm. La app protege parcialmente de esto: si el
servidor responde `403` o `409` (mount ocupado), el mensaje al DJ lo dice
explicitamente y no lo deja creyendo que esta al aire.

---

## Distribuir la app a otra emisora

1. Compila con `tool\build_windows.ps1`. La carpeta a entregar es
   `build\windows\x64\runner\Release\`.
2. El script copia `ffmpeg.exe`, su licencia, el `README.md` y `THIRD_PARTY.md`
   dentro de esa carpeta.
3. **Revisa `THIRD_PARTY.md` antes de distribuir**: si usas una build GPL de
   FFmpeg hay obligaciones que acompanan al binario (no al codigo de Xtreme
   Studio, que se ejecuta como proceso aparte). Para vender la app conviene una
   build **LGPL**.
4. La app no necesita instalador: es una carpeta portatil. El DJ la descomprime,
   la abre y carga las credenciales de su servidor.

Cada DJ guarda sus propias credenciales cifradas con DPAPI en **su** usuario de
Windows, asi que no hay nada que configurar en un servidor central ni datos que
viajen a terceros.
