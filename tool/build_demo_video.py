#!/usr/bin/env python3
"""Genera el video demo de Xtreme Studio Cast con voz en off y capturas reales.

El video resultante queda en docs/video/xtreme-studio-demo-1080p.mp4.
La voz se sintetiza con el endpoint público de Google Translate; si no hay red,
el guion queda igualmente en docs/video/guion-voz-en-off.md para grabarlo a mano.

Uso:
    python3 tool/build_demo_video.py

Requiere Pillow y el FFmpeg incluido en tools/ffmpeg.
"""
from __future__ import annotations

import array
import math
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import wave
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "video"
WORK = ROOT / ".tooling" / "demo-video"
FFMPEG = ROOT / "tools" / "ffmpeg"
ICON = ROOT / "assets" / "icon" / "app_icon.png"
FONT_BOLD = Path("/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf")
FONT_REG = Path("/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf")
FONT_MONO = Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf")

W, H = 1920, 1080
FPS = 30
LEAD = 0.35
TAIL = 0.55
PAUSE = 0.12


@dataclass
class Scene:
    key: str
    kicker: str
    title: str
    bullets: list[str]
    narration: list[str]
    image: str | None = None
    kind: str = "screen"


SCENES = [
    Scene(
        "intro",
        "DEMO · XTREME STUDIO",
        "Transmite tu radio,\nsin límites.",
        ["Windows + Linux", "Icecast2 + Shoutcast", "Soundboard y vúmetro"],
        [
            "Xtreme Studio Cast es una consola de radio para Windows y Linux.",
            "En este video te muestro cómo salir al aire, administrar tus emisoras y usar el soundboard.",
        ],
        kind="intro",
    ),
    Scene(
        "emision",
        "01 · EMISIÓN",
        "Salí al aire\nen un clic.",
        ["Vúmetro en tiempo real", "Estado AL AIRE y tiempo", "Título para tus oyentes"],
        [
            "Esta es la pantalla de emisión. Elegís tu emisora, hablás por el micrófono y ves el nivel en tiempo real.",
            "El vúmetro funciona incluso antes de salir al aire. Cuando estés listo, pulsás Entrar al aire.",
            "El estado cambia a AL AIRE, empieza el tiempo de emisión, y desde acá actualizás el título que ven tus oyentes.",
        ],
        image="docs/screenshots/linux-al-aire.png",
    ),
    Scene(
        "emisoras",
        "02 · EMISORAS",
        "Todas tus radios,\nen un solo lugar.",
        ["Perfiles Icecast2 / Shoutcast", "Host, puerto y mount", "Probar conexión"],
        [
            "En Emisoras guardás todas tus radios. Cada perfil tiene host, puerto, mount y calidad de audio.",
            "Es compatible con Icecast2 y Shoutcast. Antes de emitir, Probá conexión y la app te dice si el servidor responde.",
        ],
        image="docs/screenshots/linux-emisoras.png",
    ),
    Scene(
        "audio",
        "03 · AUDIO",
        "Tu micrófono,\ntu nivel.",
        ["Micrófono o consola", "Ganancia en vivo", "Grabación local"],
        [
            "En Ajustes elegís el micrófono o la consola. La app no abre ninguna entrada hasta que vos la elegís.",
            "También podés ajustar la ganancia en vivo, sin cortar la emisión, y activar la grabación local para guardar una copia de lo que escuchan tus oyentes.",
        ],
        image="docs/screenshots/linux-ajustes.png",
    ),
    Scene(
        "codecs",
        "04 · CALIDAD",
        "La calidad\nla elegís vos.",
        ["MP3 · AAC-LC · AAC+", "Bitrate por emisora", "Detección de encoders"],
        [
            "Cada emisora puede usar su propio códec y bitrate: MP3, AAC-LC o AAC+.",
            "La app detecta los encoders de FFmpeg y te avisa si falta alguno. Así elegís la calidad justa para tu conexión.",
        ],
        image="docs/screenshots/linux-codecs.png",
    ),
    Scene(
        "soundboard",
        "05 · SOUNDBOARD",
        "Jingles sin cortar\nla emisión.",
        ["8 pads con teclas 1–8", "Cue local", "Ducking automático"],
        [
            "El soundboard tiene ocho pads para jingles, cortinas y efectos.",
            "Podés dispararlos con las teclas uno a ocho, escucharlos solo en tu equipo con cue local, o mezclarlos al aire con ducking automático para que no tapen tu voz.",
        ],
        image="docs/screenshots/linux-soundboard.png",
    ),
    Scene(
        "updates",
        "06 · SIEMPRE AL DÍA",
        "Se mantiene\nal día.",
        ["Windows y Linux", "Actualización automática", "SHA-256 y copia de seguridad", "Sin nube"],
        [
            "Xtreme Studio Cast también se mantiene al día. En Windows y Linux comprueba si hay una versión nueva, verifica el SHA-256 y se actualiza sola.",
            "Tus emisoras, claves y soundboard quedan en tu carpeta de usuario, separados de la aplicación.",
        ],
        kind="platforms",
    ),
    Scene(
        "outro",
        "XTREME STUDIO",
        "Nos vemos\nal aire.",
        ["Descarga gratuita", "Manual en PDF", "GitHub y comentarios"],
        [
            "Xtreme Studio Cast es gratis y sin cuentas. Descargalo en la web, leé el manual y dejá tus comentarios en GitHub.",
            "Si te sirve, una estrella ayuda a que más radios lo encuentren. Nos vemos al aire.",
        ],
        kind="outro",
    ),
]


def run(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, **kwargs)


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size)


def wrap(draw: ImageDraw.ImageDraw, text: str, f, max_w: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    line = ""
    for word in words:
        probe = f"{line} {word}".strip()
        if draw.textlength(probe, font=f) <= max_w:
            line = probe
        else:
            if line:
                lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def background() -> Image.Image:
    im = Image.new("RGB", (W, H), (7, 10, 16))
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    # Resplandor rojo de marca en la esquina superior derecha.
    for i in range(18, 0, -1):
        alpha = int(4 + (18 - i) * 0.9)
        radius = 340 + i * 45
        d.ellipse(
            (W - radius - 100, -radius + 80, W + radius - 100, radius + 80),
            fill=(229, 57, 53, alpha),
        )
    # Líneas verticales muy sutiles.
    for x in range(0, W, 80):
        d.line((x, 0, x, H), fill=(255, 255, 255, 5), width=1)
    for y in range(0, H, 80):
        d.line((0, y, W, y), fill=(255, 255, 255, 4), width=1)
    im = Image.alpha_composite(im.convert("RGBA"), overlay).convert("RGB")
    # Viñeta inferior.
    shade = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shade)
    for y in range(H):
        sd.line((0, y, W, y), fill=int(90 * (y / H) ** 2))
    black = Image.new("RGB", (W, H), (0, 0, 0))
    return Image.composite(black, im, shade)


def rounded_card(im: Image.Image, box: tuple[int, int, int, int], radius: int = 18) -> None:
    x0, y0, x1, y1 = box
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((x0 + 8, y0 + 10, x1 + 8, y1 + 10), radius=radius, fill=(0, 0, 0))
    d.rounded_rectangle(box, radius=radius, fill=(13, 17, 25), outline=(45, 53, 68), width=1)


def paste_rounded(base: Image.Image, img: Image.Image, box: tuple[int, int, int, int], radius: int = 14) -> None:
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    fitted = img.copy()
    fitted.thumbnail((w, h), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (w, h), (13, 17, 25))
    canvas.paste(fitted, ((w - fitted.width) // 2, (h - fitted.height) // 2))
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w, h), radius=radius, fill=255)
    base.paste(canvas, (x0, y0), mask)


def header(im: Image.Image, d: ImageDraw.ImageDraw, scene: Scene, idx: int) -> None:
    icon = Image.open(ICON).convert("RGBA").resize((44, 44), Image.Resampling.LANCZOS)
    im.paste(icon, (80, 46), icon)
    f_brand = font(FONT_BOLD, 17)
    d.text((136, 56), "XTREME", font=f_brand, fill=(245, 247, 251))
    d.text((136 + d.textlength("XTREME ", font=f_brand), 56), "STUDIO", font=f_brand, fill=(229, 57, 53))
    f_num = font(FONT_MONO, 14)
    d.text((W - 80 - d.textlength(f"{idx:02d} / {len(SCENES):02d}", font=f_num), 60),
           f"{idx:02d} / {len(SCENES):02d}", font=f_num, fill=(120, 132, 151))


def footer(im: Image.Image, d: ImageDraw.ImageDraw, idx: int) -> None:
    d.line((80, 1034, W - 80, 1034), fill=(35, 43, 56), width=1)
    f = font(FONT_REG, 12)
    d.text((80, 1046), "XTREME STUDIO · TRANSMITE TU RADIO, SIN LÍMITES", font=f, fill=(100, 112, 133))
    d.text((W - 80 - d.textlength("DEMO 2026", font=f), 1046), "DEMO 2026", font=f, fill=(100, 112, 133))
    # Barra de progreso.
    d.rectangle((80, 1020, W - 80, 1023), fill=(28, 35, 46))
    d.rectangle((80, 1020, 80 + int((W - 160) * (idx / len(SCENES))), 1023), fill=(229, 57, 53))


def screen_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    header(im, d, scene, idx)
    # Texto de la izquierda.
    f_kick = font(FONT_BOLD, 15)
    d.text((80, 160), scene.kicker, font=f_kick, fill=(229, 57, 53))
    d.line((80, 186, 160, 186), fill=(229, 57, 53), width=3)
    f_title = font(FONT_BOLD, 52)
    y = 220
    for line in scene.title.split("\n"):
        d.text((80, y), line, font=f_title, fill=(243, 246, 251))
        y += 63
    f_bullet = font(FONT_REG, 21)
    y += 24
    for bullet in scene.bullets:
        d.ellipse((82, y + 10, 90, y + 18), fill=(229, 57, 53))
        d.text((106, y), bullet, font=f_bullet, fill=(168, 178, 194))
        y += 40
    # Captura.
    if scene.image:
        shot = Image.open(ROOT / scene.image).convert("RGB")
        max_w, max_h = 1190, 710
        scale = min(max_w / shot.width, max_h / shot.height)
        sw, sh = int(shot.width * scale), int(shot.height * scale)
        x0 = 620 + (1190 - sw) // 2
        y0 = 175 + (710 - sh) // 2
        rounded_card(im, (x0 - 8, y0 - 8, x0 + sw + 8, y0 + sh + 8))
        paste_rounded(im, shot, (x0, y0, x0 + sw, y0 + sh))
    footer(im, d, idx)
    return im


def intro_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    icon = Image.open(ICON).convert("RGBA").resize((150, 150), Image.Resampling.LANCZOS)
    im.paste(icon, ((W - 150) // 2, 160), icon)
    f_kick = font(FONT_MONO, 16)
    kick = "DEMO · XTREME STUDIO"
    d.text(((W - d.textlength(kick, font=f_kick)) / 2, 345), kick, font=f_kick, fill=(229, 57, 53))
    f_title = font(FONT_BOLD, 84)
    lines = scene.title.split("\n")
    y = 390
    for i, line in enumerate(lines):
        color = (229, 57, 53) if i else (243, 246, 251)
        d.text(((W - d.textlength(line, font=f_title)) / 2, y), line, font=f_title, fill=color)
        y += 96
    f_sub = font(FONT_REG, 24)
    sub = "Consola de radio para Windows y Linux"
    d.text(((W - d.textlength(sub, font=f_sub)) / 2, y + 10), sub, font=f_sub, fill=(168, 178, 194))
    chips = ["Windows + Linux", "Icecast2 + Shoutcast", "Soundboard y vúmetro"]
    f_chip = font(FONT_BOLD, 15)
    widths = [d.textlength(c, font=f_chip) + 34 for c in chips]
    total = sum(widths) + 14 * (len(chips) - 1)
    x = (W - total) / 2
    cy = 800
    for c, cw in zip(chips, widths):
        d.rounded_rectangle((x, cy, x + cw, cy + 40), radius=20, fill=(18, 23, 33), outline=(48, 57, 72), width=1)
        d.text((x + 17, cy + 11), c, font=f_chip, fill=(205, 214, 228))
        x += cw + 14
    f_url = font(FONT_MONO, 14)
    url = "envidia1972-create.github.io/xtreme_studio"
    d.text(((W - d.textlength(url, font=f_url)) / 2, 960), url, font=f_url, fill=(100, 112, 133))
    footer(im, d, idx)
    return im


def platforms_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    header(im, d, scene, idx)
    f_kick = font(FONT_BOLD, 15)
    d.text((80, 160), scene.kicker, font=f_kick, fill=(229, 57, 53))
    d.line((80, 186, 160, 186), fill=(229, 57, 53), width=3)
    f_title = font(FONT_BOLD, 54)
    y = 220
    for line in scene.title.split("\n"):
        d.text((80, y), line, font=f_title, fill=(243, 246, 251))
        y += 65
    f_bullet = font(FONT_REG, 21)
    y += 20
    for bullet in scene.bullets:
        d.ellipse((82, y + 10, 90, y + 18), fill=(229, 57, 53))
        d.text((106, y), bullet, font=f_bullet, fill=(168, 178, 194))
        y += 40
    # Tarjetas de plataforma.
    cards = [
        ("WINDOWS", "10 / 11 x64", "ZIP portable"),
        ("LINUX", "x64", "tar.gz portable"),
    ]
    f_platform = font(FONT_MONO, 17)
    f_os = font(FONT_BOLD, 32)
    f_detail = font(FONT_REG, 18)
    x = 620
    for name, os_name, kind in cards:
        d.rounded_rectangle((x, 230, x + 560, 720), radius=18, fill=(13, 17, 25), outline=(45, 53, 68), width=1)
        d.text((x + 34, 275), name, font=f_platform, fill=(229, 57, 53))
        d.text((x + 34, 330), os_name, font=f_os, fill=(243, 246, 251))
        d.text((x + 34, 390), kind, font=f_detail, fill=(168, 178, 194))
        d.line((x + 34, 460, x + 526, 460), fill=(35, 43, 56), width=1)
        d.text((x + 34, 500), "Actualización automática", font=f_detail, fill=(210, 219, 232))
        d.text((x + 34, 536), "SHA-256 verificado", font=f_detail, fill=(210, 219, 232))
        d.text((x + 34, 572), "Datos fuera del portable", font=f_detail, fill=(210, 219, 232))
        d.rounded_rectangle((x + 34, 630, x + 240, 675), radius=8, fill=(229, 57, 53))
        d.text((x + 56, 643), "DESCARGAR", font=font(FONT_BOLD, 14), fill=(255, 255, 255))
        x += 600
    f_url = font(FONT_MONO, 15)
    url = "envidia1972-create.github.io/xtreme_studio"
    d.text((W - 80 - d.textlength(url, font=f_url), 968), url, font=f_url, fill=(100, 112, 133))
    footer(im, d, idx)
    return im


def outro_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    icon = Image.open(ICON).convert("RGBA").resize((110, 110), Image.Resampling.LANCZOS)
    im.paste(icon, (80, 90), icon)
    f_kick = font(FONT_MONO, 15)
    d.text((80, 240), scene.kicker, font=f_kick, fill=(229, 57, 53))
    f_title = font(FONT_BOLD, 84)
    y = 290
    for line in scene.title.split("\n"):
        d.text((80, y), line, font=f_title, fill=(243, 246, 251))
        y += 95
    f_sub = font(FONT_REG, 24)
    d.text((80, y + 12), "Transmite tu radio, sin límites.", font=f_sub, fill=(168, 178, 194))
    f_url = font(FONT_BOLD, 27)
    d.text((80, 700), "envidia1972-create.github.io/xtreme_studio", font=f_url, fill=(255, 255, 255))
    f_small = font(FONT_REG, 17)
    d.text((80, 745), "Descarga · Manual · GitHub · Comentarios", font=f_small, fill=(168, 178, 194))
    # Marco de llamado a la acción.
    d.rounded_rectangle((80, 830, 760, 900), radius=12, fill=(229, 57, 53))
    d.text((110, 849), "DESCARGAR XTREME STUDIO", font=font(FONT_BOLD, 19), fill=(255, 255, 255))
    # Mini app shot a la derecha.
    shot = Image.open(ROOT / "docs/screenshots/linux-al-aire.png").convert("RGB")
    sw = 760
    sh = int(shot.height * sw / shot.width)
    shot = shot.resize((sw, sh), Image.Resampling.LANCZOS)
    rounded_card(im, (980, 300, 980 + sw + 8, 300 + sh + 8))
    paste_rounded(im, shot, (988, 308, 988 + sw, 308 + sh))
    footer(im, d, idx)
    return im


def render_scene(scene: Scene, idx: int) -> Image.Image:
    if scene.kind == "intro":
        return intro_scene(scene, idx)
    if scene.kind == "platforms":
        return platforms_scene(scene, idx)
    if scene.kind == "outro":
        return outro_scene(scene, idx)
    return screen_scene(scene, idx)


# --------------------------------------------------------------------- voz
def split_tts(text: str, limit: int = 170) -> list[str]:
    text = " ".join(text.split())
    if len(text) <= limit:
        return [text]
    parts: list[str] = []
    current = ""
    for sentence in text.replace("?", "?|").replace(".", ".|").replace("!", "!|").split("|"):
        sentence = sentence.strip()
        if not sentence:
            continue
        candidate = f"{current} {sentence}".strip()
        if len(candidate) <= limit:
            current = candidate
        else:
            if current:
                parts.append(current)
            current = sentence
    if current:
        parts.append(current)
    return parts


def tts(text: str, dest: Path) -> None:
    params = urllib.parse.urlencode({
        "ie": "UTF-8",
        "client": "tw-ob",
        "tl": "es",
        "q": text,
    })
    url = f"https://translate.google.com/translate_tts?{params}"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as response:
        data = response.read()
    if len(data) < 1200:
        raise RuntimeError(f"TTS devolvio muy pocos bytes: {len(data)}")
    dest.write_bytes(data)
    time.sleep(0.15)


def read_wav(path: Path) -> tuple[int, bytes]:
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise RuntimeError(f"WAV inesperado: {path}")
        return sr, w.readframes(w.getnframes())


def scene_voice(scene: Scene, index: int) -> tuple[Path, float, list[tuple[float, float, str]]]:
    chunk_dir = WORK / f"tts-{index:02d}"
    chunk_dir.mkdir(parents=True, exist_ok=True)
    chunks: list[tuple[Path, str]] = []
    for cidx, text in enumerate(scene.narration):
        for sidx, part in enumerate(split_tts(text)):
            mp3 = chunk_dir / f"{cidx:02d}-{sidx:02d}.mp3"
            wav = chunk_dir / f"{cidx:02d}-{sidx:02d}.wav"
            if not mp3.exists():
                tts(part, mp3)
            run([
                str(FFMPEG), "-y", "-loglevel", "error", "-i", str(mp3),
                "-ar", "48000", "-ac", "1", str(wav),
            ])
            chunks.append((wav, part))
    sr = 48000
    silence = b"\x00\x00" * int(sr * PAUSE)
    frames = bytearray()
    timings: list[tuple[float, float, str]] = []
    cursor = LEAD
    for wav, text in chunks:
        wav_sr, data = read_wav(wav)
        if wav_sr != sr:
            raise RuntimeError(f"Frecuencia inesperada en {wav}: {wav_sr}")
        duration = len(data) / 2 / sr
        timings.append((cursor, cursor + duration, text))
        frames.extend(data)
        frames.extend(silence)
        cursor += duration + PAUSE
    total = max(cursor + TAIL, 6.0)
    # Relleno final hasta la duracion exacta de la escena.
    frames.extend(b"\x00\x00" * int(sr * max(0.0, total - len(frames) / 2 / sr)))
    out = WORK / f"voice-{index:02d}.wav"
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(frames))
    return out, total, timings


def srt_time(seconds: float) -> str:
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def main() -> int:
    if not FFMPEG.exists():
        print(f"Falta FFMPEG: {FFMPEG}", file=sys.stderr)
        return 1
    if not FONT_BOLD.exists() or not FONT_REG.exists():
        print("Faltan las fuentes Noto Sans", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    for stale in WORK.glob("scene-*.mp4"):
        stale.unlink()

    scene_files: list[Path] = []
    srt_entries: list[tuple[float, float, str]] = []
    total = 0.0

    for index, scene in enumerate(SCENES, start=1):
        print(f"[{index}/{len(SCENES)}] {scene.key}: voz")
        voice, duration, timings = scene_voice(scene, index)
        print(f"    duracion: {duration:.1f}s")
        for start, end, text in timings:
            srt_entries.append((total + start, total + end, text))
        image = render_scene(scene, index - 1)
        png = WORK / f"scene-{index:02d}.png"
        image.save(png)
        mp4 = WORK / f"scene-{index:02d}.mp4"
        fade_out = max(0.1, duration - 0.35)
        vf = (
            f"scale={W}:{H},format=yuv420p,"
            f"fade=t=in:st=0:d=0.35,fade=t=out:st={fade_out:.3f}:d=0.35"
        )
        print(f"    video: {mp4.name}")
        run([
            str(FFMPEG), "-y", "-loglevel", "error",
            "-loop", "1", "-framerate", str(FPS), "-i", str(png),
            "-i", str(voice),
            "-t", f"{duration:.3f}",
            "-vf", vf,
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "19",
            "-c:a", "aac", "-b:a", "160k", "-ar", "48000",
            "-movflags", "+faststart",
            str(mp4),
        ])
        scene_files.append(mp4)
        total += duration

    concat = WORK / "concat.txt"
    concat.write_text("".join(f"file '{p.name}'\n" for p in scene_files), encoding="utf-8")
    final = OUT / "xtreme-studio-demo-1080p.mp4"
    print(f"[final] {final}")
    run([
        str(FFMPEG), "-y", "-loglevel", "error",
        "-f", "concat", "-safe", "0", "-i", str(concat),
        "-c", "copy", "-movflags", "+faststart",
        str(final),
    ])

    srt = OUT / "xtreme-studio-demo.srt"
    with srt.open("w", encoding="utf-8") as fh:
        for i, (start, end, text) in enumerate(srt_entries, start=1):
            fh.write(f"{i}\n{srt_time(start)} --> {srt_time(end)}\n{text}\n\n")
    print(f"[subtitulos] {srt}")
    print(f"[ok] {final} ({total:.1f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
