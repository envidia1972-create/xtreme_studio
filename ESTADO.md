# Estado del proyecto y qué falta

Documento de relevo. Existe porque el trabajo se detuvo en un punto concreto y
quien lo retome (o el propio autor dentro de un mes) necesita saber **exactamente
dónde está el corte** sin reconstruirlo desde cero.

Fecha del corte: ronda 11 de trabajo. Ultima verificacion: **176 comprobaciones
automaticas en verde**.

---

## Que esta hecho y verificado

El codigo de Xtreme Studio esta **completo y verificado** en todo lo que se puede
comprobar sin ejecutarlo:

| Area | Estado |
|---|---|
| Gestor de emisoras (crear, editar, duplicar, borrar) | Verificado |
| Icecast 2 + Shoutcast v1/v2 (handshake propio, sin ffmpeg) | Verificado |
| Credenciales cifradas con DPAPI | Verificado |
| "Probar conexion" con diagnostico por codigo HTTP | Verificado |
| Captura y codificacion MP3 por FFmpeg | Argumentos verificados; **captura real no ejecutada** |
| Motor de emision, reconexion y deteccion de caida | Logica verificada; **proceso real no lanzado** |
| Metadatos `icy-metaint` (entrelazado) | Verificado parseando el flujo |
| Vumetros de pico y RMS | Verificado con ondas sinteticas |
| Grabacion local | Logica verificada |
| Ganancia de entrada por emisora | Verificado hasta el filtro de FFmpeg |
| Monitor de senal (vista del oyente) | Verificado, y probado contra el servidor real |
| Proteccion del mount ocupado | Verificado, incluida la peticion `mode=delete` |
| Handshake contra el servidor real del usuario | **Ejecutado con exito** |

### Comprobaciones ejecutables en cualquier momento

```powershell
cd C:\Desarrollo\xtreme_studio
$env:APPDATA = 'C:\Desarrollo\xtreme_studio\.tmp_appdata'
$env:PUB_CACHE = 'C:\Desarrollo\xtreme_studio\.pubcache'
dart run tool\verify_core.dart             # 103 comprobaciones
dart run tool\verify_ui.dart               #  18 comprobaciones
dart run tool\verify_ffmpeg_discovery.dart #  18 comprobaciones
dart run tool\verify_signal.dart           #  23 comprobaciones
dart run tool\verify_occupied_mount.dart   #  14 comprobaciones
```

---

## Donde se detuvo, exactamente

Dos bloqueos **independientes**. Resolver uno solo no desbloquea el trabajo.

### 1. El entorno de desarrollo no puede compilar (limite del entorno)

Medido en tres vias distintas:

| Via | Resultado |
|---|---|
| `flutter build windows` con el SDK normal | Falla: no puede escribir su `lockfile` en el SDK (fuera del area permitida) |
| SDK de Flutter local con junctions | El tool arranca, pero muere al lanzar `git` |
| `dart compile exe` (ejecutable AOT) | Falla: no puede lanzar `dartaotruntime` |

**Causa:** el sandbox permite que el shell lance procesos, pero **bloquea el
lanzamiento de procesos desde cualquier programa Dart**
(`ProcessException: Acceso denegado`), y deja el SDK de Flutter en solo lectura.
El tool de Flutter necesita las dos cosas: escribir su `lockfile` y lanzar
`git`, `cmake`, `cl.exe` y el propio backend.

**Consecuencia:** `tool\verify_engine.dart` (la prueba de integracion del motor,
que si lanza FFmpeg) tampoco se puede ejecutar aqui.

### 2. Falta FFmpeg, y no se puede descargar desde aqui

- No hay ningun `ffmpeg.exe` en el equipo (buscado en `PATH`, winget,
  Chocolatey, Scoop, Descargas, `Program Files`).
- Descargarlo **no es posible**: el TLS del sistema esta roto
  (`Schannel: SEC_E_NO_CREDENTIALS`), lo que afecta a toda conexion HTTPS.
  Se probo tambien `choco install` (exige HTTPS y falla igual).

---

## Los dos pasos que faltan

```powershell
cd C:\Desarrollo\xtreme_studio

# 1. Comprobar que el equipo puede compilar (no compila nada, tarda segundos)
powershell -ExecutionPolicy Bypass -File tool\check_toolchain.ps1

# 2. Poner FFmpeg en su sitio
#    Descargar una build "full" o "gpl" de https://www.gyan.dev/ffmpeg/builds/
#    y copiar ffmpeg.exe a  C:\Desarrollo\xtreme_studio\tools\

# 3. Compilar
powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1

# 4. Prueba de integracion del motor (la que aqui no se puede correr)
dart run tool\verify_engine.dart
```

Salida esperada: `build\windows\x64\runner\Release\xtreme_studio.exe`, con
`ffmpeg.exe`, la licencia y la documentacion copiadas al lado.

### Si algo falla al compilar

`tool\check_toolchain.ps1` dice que falta. Estado comprobado en este equipo:

```
[ok] Flutter 3.47.1 / Dart 3.13.1
[ok] Visual Studio Build Tools con C++
[ok] CMake incluido en Visual Studio
[ok] Compilador cl.exe (14.50.35717)
[ok] Windows SDK (10.0.26100.0)
[aviso] FFmpeg no encontrado        <-- unico pendiente
```

---

## Prueba en vivo: leer antes de intentarla

El servidor de prueba del usuario es **Zeno.fm**:

- Host de **escucha**: `link.zeno.fm` (redirige al CDN)
- Host de **publicacion**: `stream.zeno.fm:8000`
- Mount: `/5tmrzbywtzzuv`, clave `vffVssdL`
- Estado verificado por sondas: **al aire con "LatinSound 507"** (audio AAC)

> **Antes de emitir en ese mount, confirmar que la cabina esta libre.** Conectar
> una fuente ahi desplaza a quien este transmitiendo.

Notas importantes de ese hosting, medidas con sondas reales:

1. **`stream.zeno.fm:8000` acepta el handshake con credenciales validas.** El
   mount efectivo puede ser `/5tmrzbywtzzuv` o `/5tmrzbywtzzuv/source`; ambos
   respondieron igual. Confirmar con un mount libre antes de la prueba final.
2. **Zeno.fm rechaza `HEAD` con 405** pero sirve el audio con `GET`. Por eso el
   monitor de senal usa `GET` (ver `stream_health.dart`); cambiarlo a `HEAD`
   rompe la comprobacion.
3. **Zeno.fm no devuelve 403 cuando el mount esta ocupado**: el handshake se
   acepta siempre. La proteccion del mount ocupado (ronda 9) **no actua** en ese
   hosting. Hay que coordinarlo a mano.

Sondas disponibles (ambas de solo lectura, no desplazan a nadie):

```powershell
dart run tool\probe_icecast.dart   # handshake de publicacion, sin enviar audio
dart run tool\probe_signal.dart    # comprueba que el mount se sirve
```

---

## Que queda pendiente de funcionalidad

Del plan original, sin empezar:

- **Soundboard** con teclas rapidas (jingles, cortinas). Requiere mezclar audio
  en vivo, que hoy no esta implementado: la app captura, codifica y envia, pero
  no mezcla dos fuentes.
- **Escuchar la propia senal** (monitoreo). Se retiro el ajuste porque nunca se
  implemento; requeriria decodificar el MP3 de salida.
- **API de administracion** de AzuraCast/Icecast (expulsar a un DJ, consultar
  quien esta al aire). Los campos `adminUsername`/`adminPassword` del perfil se
  guardan desde ahora, pero **no se usan todavia**.
- **Notificaciones push** y **panel web** de la fase 3 del plan.

Nada de esto esta a medias: simplemente no se empezo.
