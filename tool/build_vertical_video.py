#!/usr/bin/env python3
"""Genera el video vertical de 60 s para Reels, TikTok y Shorts.

Salida: docs/video/xtreme-studio-vertical-60s.mp4 (1080x1920).
La voz se sintetiza con Google Translate; el guion queda en
docs/video/guion-vertical-60s.md para reemplazarla por una voz humana.
"""
from __future__ import annotations

import array
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import wave
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "video"
WORK = ROOT / ".tooling" / "vertical-video"
FFMPEG = ROOT / "tools" / "ffmpeg"
ICON = ROOT / "assets" / "icon" / "app_icon.png"
FONT_BOLD = Path("/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf")
FONT_REG = Path("/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf")
FONT_MONO = Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf")

W, H = 1080, 1920
FPS = 30
LEAD = 0.30
TAIL = 0.40
PAUSE = 0.10


@dataclass
class Scene:
    key: str
    kicker: str
    title: str
    bullets: list[str]
    narration: list[str]
    target: float
    image: str | None = None
    kind: str = "screen"
    quote: str = ""


SCENES = [
    Scene(
        "hook", "XTREME STUDIO", "Transmite tu radio,\nsin límites.",
        ["Windows + Linux", "Icecast2 + Shoutcast"],
        ["Transmite tu radio, sin límites."], 5.5, kind="intro",
    ),
    Scene(
        "emision", "01 · EMISIÓN", "Salí al aire\nen un clic.",
        ["Vúmetro en vivo", "Título para tus oyentes"],
        ["Elegís tu emisora, hablás y salís al aire.", "Vúmetro en vivo y título para tus oyentes."],
        10.0, image="docs/screenshots/linux-al-aire.png",
        quote="Tu voz, en vivo.\nSin ventanas de por medio.",
    ),
    Scene(
        "emisoras", "02 · EMISORAS", "Todas tus radios,\nen un solo lugar.",
        ["Icecast2 y Shoutcast", "Prueba de conexión"],
        ["Todas tus radios, en un solo lugar.", "Icecast2 y Shoutcast, con prueba de conexión."],
        9.0, image="docs/screenshots/linux-emisoras.png",
        quote="Tus radios, tus reglas.\nIcecast2 + Shoutcast.",
    ),
    Scene(
        "soundboard", "03 · SOUNDBOARD", "Jingles\nsin cortar la emisión.",
        ["8 pads · teclas 1–8", "Cue local y ducking"],
        ["Jingles con ocho pads, cue local y ducking.", "Para que no tapen tu voz."],
        9.0, image="docs/screenshots/linux-soundboard.png",
        quote="Jingles al aire.\nSin cortar el stream.",
    ),
    Scene(
        "audio", "04 · AUDIO Y CALIDAD", "Tu micrófono,\ntu nivel.",
        ["Ganancia en vivo", "MP3 · AAC-LC · AAC+"],
        ["Micrófono, ganancia en vivo, grabación.", "Y la calidad que elijas para tu conexión."],
        9.0, image="docs/screenshots/linux-ajustes.png",
        quote="Ajustá el nivel\nsin reiniciar el micrófono.",
    ),
    Scene(
        "updates", "05 · SIEMPRE AL DÍA", "Se actualiza\nsola.",
        ["Windows y Linux", "Datos fuera del portable"],
        ["Se actualiza sola en Windows y Linux.", "Tus datos quedan fuera del portable."],
        9.0, kind="platforms",
    ),
    Scene(
        "cta", "XTREME STUDIO", "Descargala\ngratis.",
        ["Windows + Linux", "Manual y GitHub"],
        ["Descargala gratis en Xtreme Studio.", "De tu PC al aire."],
        8.5, kind="outro",
    ),
]


def run(args: list[str]) -> None:
    subprocess.run(args, check=True)


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
    for i in range(16, 0, -1):
        alpha = int(4 + (16 - i))
        radius = 250 + i * 50
        d.ellipse((W - radius, -radius + 250, W + radius, radius + 250),
                  fill=(229, 57, 53, alpha))
    for x in range(0, W, 60):
        d.line((x, 0, x, H), fill=(255, 255, 255, 5), width=1)
    for y in range(0, H, 60):
        d.line((0, y, W, y), fill=(255, 255, 255, 4), width=1)
    im = Image.alpha_composite(im.convert("RGBA"), overlay).convert("RGB")
    shade = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shade)
    for y in range(H):
        sd.line((0, y, W, y), fill=int(80 * (y / H) ** 2))
    return Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), im, shade)


def header(im: Image.Image, d: ImageDraw.ImageDraw, idx: int) -> None:
    icon = Image.open(ICON).convert("RGBA").resize((50, 50), Image.Resampling.LANCZOS)
    im.paste(icon, (50, 52), icon)
    f_brand = font(FONT_BOLD, 18)
    d.text((112, 62), "XTREME", font=f_brand, fill=(245, 247, 251))
    d.text((112 + d.textlength("XTREME ", font=f_brand), 62), "STUDIO", font=f_brand, fill=(229, 57, 53))
    f_num = font(FONT_MONO, 13)
    label = "60 SEGUNDOS" if idx == 0 else f"{idx:02d} / 07"
    d.text((W - 50 - d.textlength(label, font=f_num), 68), label, font=f_num, fill=(110, 122, 142))


def footer(im: Image.Image, d: ImageDraw.ImageDraw, idx: int) -> None:
    d.line((50, 1846, W - 50, 1846), fill=(35, 43, 56), width=1)
    f = font(FONT_REG, 12)
    d.text((50, 1858), "XTREME STUDIO · TRANSMITE TU RADIO, SIN LÍMITES", font=f, fill=(100, 112, 133))
    d.rectangle((50, 1834, W - 50, 1837), fill=(28, 35, 46))
    d.rectangle((50, 1834, 50 + int((W - 100) * (idx / 7)), 1837), fill=(229, 57, 53))
    # CTA permanente.
    d.rounded_rectangle((50, 1668, 530, 1740), radius=12, fill=(229, 57, 53))
    d.text((78, 1692), "DESCARGALA GRATIS", font=font(FONT_BOLD, 20), fill=(255, 255, 255))
    f_url = font(FONT_MONO, 13)
    url = "envidia1972-create.github.io/xtreme_studio"
    d.text((W - 50 - d.textlength(url, font=f_url), 1700), url, font=f_url, fill=(120, 132, 151))


def screenshot(im: Image.Image, d: ImageDraw.ImageDraw, path: str, top: int = 500) -> None:
    shot = Image.open(ROOT / path).convert("RGB")
    max_w = 980
    scale = max_w / shot.width
    sw, sh = max_w, int(shot.height * scale)
    x0 = (W - sw) // 2
    y0 = top
    d.rounded_rectangle((x0 + 8, y0 + 10, x0 + sw + 8, y0 + sh + 10), radius=18, fill=(0, 0, 0))
    d.rounded_rectangle((x0 - 1, y0 - 1, x0 + sw + 1, y0 + sh + 1), radius=18, fill=(45, 53, 68))
    fitted = shot.resize((sw, sh), Image.Resampling.LANCZOS)
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw, sh), radius=17, fill=255)
    im.paste(fitted, (x0, y0), mask)


def screen_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    header(im, d, idx)
    f_kick = font(FONT_BOLD, 18)
    d.text((50, 150), scene.kicker, font=f_kick, fill=(229, 57, 53))
    d.line((50, 182, 150, 182), fill=(229, 57, 53), width=3)
    f_title = font(FONT_BOLD, 64)
    y = 220
    for line in scene.title.split("\n"):
        d.text((50, y), line, font=f_title, fill=(243, 246, 251))
        y += 76
    f_bullet = font(FONT_REG, 23)
    y += 14
    for bullet in scene.bullets:
        d.ellipse((54, y + 11, 63, y + 20), fill=(229, 57, 53))
        d.text((80, y), bullet, font=f_bullet, fill=(168, 178, 194))
        y += 38
    screenshot(im, d, scene.image or "", top=500)
    if scene.quote:
        qy = 1160 if scene.image and scene.image.endswith("linux-ajustes.png") else 1100
        # La captura de ajustes es mas alta (800 px); el bloque baja un poco.
        if scene.image and scene.image.endswith("linux-soundboard.png"):
            qy = 1160
        d.rounded_rectangle((50, qy, 1030, qy + 270), radius=18, fill=(13, 17, 25), outline=(45, 53, 68), width=1)
        d.rectangle((50, qy, 56, qy + 270), fill=(229, 57, 53))
        f_q = font(FONT_BOLD, 36)
        yy = qy + 44
        for line in scene.quote.split("\n"):
            d.text((86, yy), line, font=f_q, fill=(243, 246, 251))
            yy += 48
        d.text((86, qy + 208), "XTREME STUDIO · EN VIVO", font=font(FONT_MONO, 13), fill=(120, 132, 151))
    footer(im, d, idx)
    return im


def intro_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    icon = Image.open(ICON).convert("RGBA").resize((170, 170), Image.Resampling.LANCZOS)
    im.paste(icon, ((W - 170) // 2, 270), icon)
    f_kick = font(FONT_MONO, 17)
    kick = "DEMO · 60 SEGUNDOS"
    d.text(((W - d.textlength(kick, font=f_kick)) / 2, 490), kick, font=f_kick, fill=(229, 57, 53))
    f_title = font(FONT_BOLD, 82)
    lines = scene.title.split("\n")
    y = 550
    for i, line in enumerate(lines):
        color = (229, 57, 53) if i else (243, 246, 251)
        d.text(((W - d.textlength(line, font=f_title)) / 2, y), line, font=f_title, fill=color)
        y += 94
    f_sub = font(FONT_REG, 25)
    sub = "Consola de radio para Windows y Linux"
    d.text(((W - d.textlength(sub, font=f_sub)) / 2, y + 12), sub, font=f_sub, fill=(168, 178, 194))
    chips = ["De tu PC al aire", "Sin nube", "Soundboard"]
    f_chip = font(FONT_BOLD, 16)
    for i, c in enumerate(chips):
        cy = 900 + i * 58
        tw = d.textlength(c, font=f_chip) + 42
        x = (W - tw) / 2
        d.rounded_rectangle((x, cy, x + tw, cy + 42), radius=21, fill=(18, 23, 33), outline=(48, 57, 72), width=1)
        d.text((x + 21, cy + 11), c, font=f_chip, fill=(205, 214, 228))
    footer(im, d, idx)
    return im


def platforms_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    header(im, d, idx)
    f_kick = font(FONT_BOLD, 18)
    d.text((50, 150), scene.kicker, font=f_kick, fill=(229, 57, 53))
    d.line((50, 182, 150, 182), fill=(229, 57, 53), width=3)
    f_title = font(FONT_BOLD, 64)
    y = 220
    for line in scene.title.split("\n"):
        d.text((50, y), line, font=f_title, fill=(243, 246, 251))
        y += 76
    f = font(FONT_REG, 23)
    y += 20
    for bullet in scene.bullets:
        d.ellipse((54, y + 11, 63, y + 20), fill=(229, 57, 53))
        d.text((80, y), bullet, font=f, fill=(168, 178, 194))
        y += 38
    # Tarjetas apiladas verticalmente.
    cards = [("WINDOWS", "10 / 11 x64", "ZIP portable"), ("LINUX", "x64", "tar.gz portable")]
    cy = 530
    for name, os_name, kind in cards:
        d.rounded_rectangle((50, cy, 1030, cy + 280), radius=18, fill=(13, 17, 25), outline=(45, 53, 68), width=1)
        d.text((82, cy + 34), name, font=font(FONT_MONO, 17), fill=(229, 57, 53))
        d.text((82, cy + 76), os_name, font=font(FONT_BOLD, 34), fill=(243, 246, 251))
        d.text((82, cy + 126), kind, font=font(FONT_REG, 20), fill=(168, 178, 194))
        d.line((82, cy + 176, 998, cy + 176), fill=(35, 43, 56), width=1)
        d.text((82, cy + 200), "Actualización automática · SHA-256", font=font(FONT_REG, 19), fill=(210, 219, 232))
        d.text((82, cy + 232), "Datos fuera del portable", font=font(FONT_REG, 19), fill=(210, 219, 232))
        cy += 310
    footer(im, d, idx)
    return im


def outro_scene(scene: Scene, idx: int) -> Image.Image:
    im = background()
    d = ImageDraw.Draw(im)
    icon = Image.open(ICON).convert("RGBA").resize((130, 130), Image.Resampling.LANCZOS)
    im.paste(icon, (50, 180), icon)
    f_kick = font(FONT_MONO, 17)
    d.text((50, 340), "XTREME STUDIO", font=f_kick, fill=(229, 57, 53))
    f_title = font(FONT_BOLD, 92)
    y = 390
    for line in scene.title.split("\n"):
        d.text((50, y), line, font=f_title, fill=(243, 246, 251))
        y += 104
    d.text((50, y + 10), "Transmite tu radio, sin límites.", font=font(FONT_REG, 29), fill=(168, 178, 194))
    d.text((50, 1000), "Windows + Linux", font=font(FONT_BOLD, 26), fill=(243, 246, 251))
    d.text((50, 1045), "Descarga, manual y GitHub", font=font(FONT_REG, 22), fill=(168, 178, 194))
    d.rounded_rectangle((50, 1140, 700, 1225), radius=13, fill=(229, 57, 53))
    d.text((82, 1165), "DESCARGALA GRATIS", font=font(FONT_BOLD, 22), fill=(255, 255, 255))
    d.text((50, 1280), "envidia1972-create.github.io/xtreme_studio", font=font(FONT_MONO, 20), fill=(243, 246, 251))
    d.text((50, 1322), "github.com/envidia1972-create/xtreme_studio", font=font(FONT_MONO, 17), fill=(120, 132, 151))
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


# ---------------------------------------------------------------- voz
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
    params = urllib.parse.urlencode({"ie": "UTF-8", "client": "tw-ob", "tl": "es", "q": text})
    req = urllib.request.Request(
        f"https://translate.google.com/translate_tts?{params}",
        headers={"User-Agent": "Mozilla/5.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        data = response.read()
    if len(data) < 1200:
        raise RuntimeError("TTS devolvio muy pocos bytes")
    dest.write_bytes(data)
    time.sleep(0.12)


def read_wav(path: Path) -> tuple[int, bytes]:
    with wave.open(str(path), "rb") as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise RuntimeError(f"WAV inesperado: {path}")
        return w.getframerate(), w.readframes(w.getnframes())


def scene_voice(scene: Scene, index: int) -> tuple[Path, float, list[tuple[float, float, str]]]:
    chunk_dir = WORK / f"tts-{index:02d}"
    chunk_dir.mkdir(parents=True, exist_ok=True)
    items: list[tuple[Path, str]] = []
    for cidx, text in enumerate(scene.narration):
        for sidx, part in enumerate(split_tts(text)):
            mp3 = chunk_dir / f"{cidx:02d}-{sidx:02d}.mp3"
            wav = chunk_dir / f"{cidx:02d}-{sidx:02d}.wav"
            if not mp3.exists():
                tts(part, mp3)
            run([str(FFMPEG), "-y", "-loglevel", "error", "-i", str(mp3),
                 "-ar", "48000", "-ac", "1", str(wav)])
            items.append((wav, part))
    sr = 48000
    silence = b"\x00\x00" * int(sr * PAUSE)
    frames = bytearray()
    timings: list[tuple[float, float, str]] = []
    cursor = LEAD
    for wav, text in items:
        wav_sr, data = read_wav(wav)
        if wav_sr != sr:
            raise RuntimeError(f"Frecuencia inesperada: {wav_sr}")
        duration = len(data) / 2 / sr
        timings.append((cursor, cursor + duration, text))
        frames.extend(data)
        frames.extend(silence)
        cursor += duration + PAUSE
    duration = max(scene.target, cursor + TAIL)
    frames.extend(b"\x00\x00" * int(sr * max(0.0, duration - len(frames) / 2 / sr)))
    out = WORK / f"voice-{index:02d}.wav"
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(frames))
    return out, duration, timings


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
        print(f"    {duration:.1f}s")
        for start, end, text in timings:
            srt_entries.append((total + start, total + end, text))
        image = render_scene(scene, index - 1)
        png = WORK / f"scene-{index:02d}.png"
        image.save(png)
        mp4 = WORK / f"scene-{index:02d}.mp4"
        fade_out = max(0.1, duration - 0.3)
        vf = (
            f"scale={W}:{H},format=yuv420p,"
            f"fade=t=in:st=0:d=0.3,fade=t=out:st={fade_out:.3f}:d=0.3"
        )
        run([str(FFMPEG), "-y", "-loglevel", "error",
             "-loop", "1", "-framerate", str(FPS), "-i", str(png), "-i", str(voice),
             "-t", f"{duration:.3f}", "-vf", vf,
             "-c:v", "libx264", "-preset", "veryfast", "-crf", "19",
             "-c:a", "aac", "-b:a", "160k", "-ar", "48000",
             "-movflags", "+faststart", str(mp4)])
        scene_files.append(mp4)
        total += duration
    concat = WORK / "concat.txt"
    concat.write_text("".join(f"file '{p.name}'\n" for p in scene_files), encoding="utf-8")
    final = OUT / "xtreme-studio-vertical-60s.mp4"
    run([str(FFMPEG), "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
         "-i", str(concat), "-c", "copy", "-movflags", "+faststart", str(final)])
    srt = OUT / "xtreme-studio-vertical-60s.srt"
    with srt.open("w", encoding="utf-8") as fh:
        for i, (start, end, text) in enumerate(srt_entries, start=1):
            fh.write(f"{i}\n{srt_time(start)} --> {srt_time(end)}\n{text}\n\n")
    print(f"[ok] {final} ({total:.1f}s)")
    print(f"[ok] {srt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
