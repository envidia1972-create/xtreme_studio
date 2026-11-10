#!/usr/bin/env bash
# Genera el manual PDF de la web a partir de site/manual.html.
#
# Uso:
#   tool/build_manual.sh
#
# Requiere Google Chrome o Chromium. En Ubuntu/Debian:
#   google-chrome, chromium o chromium-browser.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHROME="${CHROME:-}"
if [[ -z "$CHROME" ]]; then
  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CHROME="$candidate"
      break
    fi
  done
fi
if [[ -z "$CHROME" ]]; then
  echo "ERROR: no se encontro Chrome/Chromium. Proba: CHROME=/ruta/chrome tool/build_manual.sh" >&2
  exit 1
fi

mkdir -p site/assets
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT

"$CHROME" --headless=new --no-sandbox --disable-gpu \
  --no-pdf-header-footer --run-all-compositor-stages-before-draw \
  --virtual-time-budget=5000 --user-data-dir="$PROFILE" \
  --print-to-pdf="$ROOT/site/assets/xtreme-studio-manual.pdf" \
  "file://$ROOT/site/manual.html"

echo "Manual generado: site/assets/xtreme-studio-manual.pdf"
