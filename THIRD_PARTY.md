# Licencias de terceros

Xtreme Studio se distribuye junto a **FFmpeg**, que es el unico componente
externo que necesita para capturar y codificar audio. Este documento existe
porque el objetivo del Modo B es **vender o ceder la app a otras emisoras**, y
en ese momento las licencias dejan de ser un detalle.

---

## FFmpeg (no incluido en el repositorio)

Xtreme Studio **no incluye** FFmpeg en su codigo fuente: el usuario lo descarga
por separado o el instalador lo copia. Esto es deliberado.

FFmpeg es un proyecto separado y se ejecuta como **proceso independiente**:
Xtreme Studio lo lanza con argumentos y lee su salida. No se enlaza su codigo ni
se deriva obra de el.

### Que licencia aplica

Depende de la build que se distribuya:

| Build | Licencia | Que implica al redistribuir |
|---|---|---|
| **LGPL** (por ejemplo `ffmpeg-release-essentials`) | LGPL v2.1+ | Se puede distribuir con una app propietaria. Hay que acompanar el texto de la licencia y permitir reemplazar el binario. |
| **GPL** (por ejemplo `ffmpeg-release-full`, o cualquier build con `--enable-gpl`) | GPL v2+/v3 | Al distribuir la app junto al binario, la obligacion de la GPL recae **sobre FFmpeg**, no sobre el codigo de Xtreme Studio, porque se ejecuta como proceso aparte. Igual conviene acompanar la licencia y ofrecer el codigo fuente de FFmpeg. |
| Build con `libx264`, `libx265`, `libfdk_aac` | GPL y/o patentes | **Evitar.** Xtreme Studio solo usa `libmp3lame`, que no requiere esas librerias. |

### Recomendacion practica

1. Para uso interno (tu propia radio): cualquier build sirve.
2. Para distribuir la app a terceros: usar una build **LGPL** y copiar su
   `LICENSE` junto al ejecutable. Los scripts `tool\build_windows.ps1` y
   `tool/build_linux.sh` ya lo hacen automaticamente cuando encuentran el
   archivo.
3. No es necesario publicar el codigo de Xtreme Studio: el audio se codifica con
   `libmp3lame` (MP3, sin royalties) y **no** se usa AAC ni H.264.

### AAC / AAC+

Xtreme Studio puede enviar **AAC-LC** con el encoder nativo de FFmpeg y
**AAC+ (HE-AAC)** si la build incluye `libfdk_aac`.

- El encoder `aac` nativo de FFmpeg es LGPL y se puede usar sin obligaciones
  adicionales sobre la app.
- `libfdk_aac` es la biblioteca de Fraunhofer FDK AAC. Se distribuye bajo una
  licencia propia que **no es libre para todos los usos**; ademas, una build de
  FFmpeg con `--enable-libfdk-aac` requiere `--enable-nonfree`. Esa build **no
  se incluye** en `tools/`: si el usuario la aporta, la responsabilidad de su
  licencia es del usuario. AAC+ solo aparece en la app cuando la build la
  expone en `ffmpeg -encoders`.

### Sobre las patentes de MP3

Las patentes del MP3 **expiraron** (las ultimas en 2017), por lo que codificar
en MP3 no genera obligaciones de regalias. Se eligio MP3 justamente por eso:
AAC habria implicado licencias de patentes para un producto comercial.

---

## Dependencias de Dart

Todas con licencias permisivas, compatibles con un producto propietario:

| Paquete | Licencia | Para que se usa |
|---|---|---|
| `ffi` | BSD-3-Clause | Llamar a `CryptProtectData` de Windows |
| `win32` | BSD-3-Clause | Enlaces a la API de Windows (DPAPI) |
| `uuid` | MIT | Identificadores de perfil |
| `flutter` / `flutter_lints` | BSD-3-Clause | Framework y reglas de estilo |

Ninguna obliga a publicar el codigo de la aplicacion.

---

## Marcas

**Xtreme Studio es una implementacion propia.** El cliente de Icecast y
Shoutcast esta escrito desde cero a partir de la documentacion publica de esos
protocolos.

Los nombres *Icecast*, *SHOUTcast*, *AzuraCast* y *Zeno.fm* pertenecen a sus
respectivos titulares y se mencionan solo para indicar compatibilidad.
