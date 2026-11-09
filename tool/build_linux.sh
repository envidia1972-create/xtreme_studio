#!/usr/bin/env bash
# Compilacion de Xtreme Studio para Linux (escritorio GTK).
#
# Deja el ejecutable en build/linux/x64/release/bundle/ y copia FFmpeg,
# la licencia y la documentacion al lado, para que la carpeta se pueda entregar
# tal cual.
#
# Uso:
#   tool/build_linux.sh
#
# Si el SDK de Flutter compartido es de solo lectura, ejecuta antes:
#   tool/setup_local_sdk.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Entorno local creado por setup_local_sdk.sh (SDK y cache escribibles).
if [[ -f "$ROOT/.tooling/env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.tooling/env.sh"
fi

FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [[ -x "$FLUTTER_BIN" ]]; then
  :
fi
if ! command -v "$FLUTTER_BIN" >/dev/null 2>&1 && [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "ERROR: no se encontro Flutter. Instalalo o ejecuta tool/setup_local_sdk.sh." >&2
  exit 1
fi

echo "== Comprobando dependencias de Linux =="
missing=0
for tool in cmake ninja clang pkg-config; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "  FALTA: $tool" >&2
    missing=1
  else
    echo "  ok: $tool ($(command -v "$tool"))"
  fi
done
if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
  echo "  FALTA: cabeceras de GTK 3 (paquete libgtk-3-dev)" >&2
  missing=1
else
  echo "  ok: gtk+-3.0 $(pkg-config --modversion gtk+-3.0)"
fi
if [[ "$missing" -ne 0 ]]; then
  echo "Instala lo que falta y volve a intentar." >&2
  exit 1
fi

echo
echo "== Resolviendo dependencias de Dart =="
"$FLUTTER_BIN" pub get

echo
echo "== Compilando (release) =="
APP_VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' pubspec.yaml | head -n1)"
APP_BUILD="$(sed -n 's/^version:[[:space:]]*[0-9][0-9.]*+\([0-9][0-9]*\).*/\1/p' pubspec.yaml | head -n1)"
: "${APP_VERSION:=0.1.0}"
: "${APP_BUILD:=1}"
echo "  Version: $APP_VERSION+$APP_BUILD"
"$FLUTTER_BIN" build linux --release \
  --dart-define=APP_VERSION="$APP_VERSION" \
  --dart-define=APP_BUILD="$APP_BUILD"

BUNDLE="$ROOT/build/linux/x64/release/bundle"
if [[ ! -x "$BUNDLE/xtreme_studio" ]]; then
  echo "ERROR: no se genero $BUNDLE/xtreme_studio" >&2
  exit 1
fi

echo
echo "== Preparando la carpeta distribuible =="
if [[ -x "$ROOT/tools/ffmpeg" ]]; then
  cp "$ROOT/tools/ffmpeg" "$BUNDLE/ffmpeg"
  chmod +x "$BUNDLE/ffmpeg"
  echo "  FFmpeg copiado junto al ejecutable"
else
  echo "  AVISO: no hay tools/ffmpeg. La app buscara ffmpeg en el PATH" >&2
  echo "         (en Ubuntu/Debian: sudo apt install ffmpeg)." >&2
fi
cp "$ROOT/README.md" "$BUNDLE/README.md" 2>/dev/null || true
cp "$ROOT/THIRD_PARTY.md" "$BUNDLE/THIRD_PARTY.md" 2>/dev/null || true
for license in \
  "$ROOT/.tooling/ffmpeg-pulse/LICENSE.txt" \
  "$ROOT/.tooling/ffmpeg-pulse/LICENSE" \
  "$ROOT/.tooling/ffmpeg-alsa/GPLv3.txt" \
  "$ROOT/tools/ffmpeg.LICENSE"; do
  if [[ -f "$license" ]]; then
    cp "$license" "$BUNDLE/FFMPEG-LICENSE.txt"
    echo "  Licencia de FFmpeg copiada: $(basename "$license")"
    break
  fi
done

echo
echo "Listo: $BUNDLE"
echo "Ejecuta:"
echo "  $BUNDLE/xtreme_studio"
