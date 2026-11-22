# Video demo de Xtreme Studio

Video de presentación de las funciones básicas, pensado para YouTube, la web o
una publicación en redes.

## Archivos

- `xtreme-studio-demo-1080p.mp4` — video final, 1920×1080, H.264 + AAC, 2:39.
- `guion-voz-en-off.md` — guion completo para grabar una voz humana o adaptar
  el texto.
- `xtreme-studio-demo.srt` — subtítulos en español sincronizados.
- `thumbnail-youtube.png` — miniatura 1280×720 para YouTube.
- `descripcion-youtube.txt` — título, descripción, capítulos y etiquetas listos
  para copiar.

## Contenido

1. Presentación de Xtreme Studio.
2. Emisión: vúmetro, entrar/salir al aire y título para los oyentes.
3. Emisoras: perfiles, Icecast2/Shoutcast y prueba de conexión.
4. Audio: micrófono, ganancia en vivo y grabación local.
5. Calidad: MP3, AAC-LC, AAC+ y bitrate por emisora.
6. Soundboard: ocho pads, cue local y ducking.
7. Descarga y actualizaciones en Windows y Linux.
8. Cierre con web, manual y GitHub.

## Voz

El video incluido usa una voz sintética en español. El guion está separado para
que se pueda reemplazar por una voz humana sin rehacer la edición:

1. Grabar cada bloque del `guion-voz-en-off.md`.
2. Reemplazar el audio del video o volver a ejecutar el generador con los
   archivos de voz propios.
3. Ajustar los tiempos de los subtítulos si cambia la duración.

## Regenerar

```bash
python3 tool/build_demo_video.py
```

Requiere Pillow, conexión a Internet para la voz sintética y el FFmpeg incluido
en `tools/ffmpeg`. Las capturas se toman de `docs/screenshots/`.

## Publicarlo en YouTube

**Título sugerido:**

```text
Xtreme Studio: tu radio desde la PC, sin intermediarios
```

**Descripción sugerida:**

```text
Xtreme Studio es una consola de radio para Windows y Linux. Emití a tu servidor
Icecast2 o Shoutcast, administrá varias emisoras, usá el soundboard y grabá tus
programas sin depender de una nube.

Descarga: https://envidia1972-create.github.io/xtreme_studio/
GitHub: https://github.com/envidia1972-create/xtreme_studio
Manual: https://envidia1972-create.github.io/xtreme_studio/manual.html

#radio #streaming #icecast #shoutcast #softwarelibre
```

**Capítulos:**

```text
00:00 Presentación
00:14 Emisión
00:40 Emisoras
01:00 Audio
01:20 Calidad y códecs
01:41 Soundboard
02:00 Actualizaciones
02:22 Cierre
```

Los subtítulos completos, con tiempos por frase, están en
`xtreme-studio-demo.srt`.

## Licencia de la música y la voz

El video no incluye música de terceros. La voz sintética se genera con el
servicio público de Google Translate; si se publica comercialmente, conviene
reemplazarla por una grabación propia.
