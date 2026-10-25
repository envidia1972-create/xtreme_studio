#!/usr/bin/env bash
# Prepara un SDK de Flutter escribible dentro del proyecto.
#
# Sirve para el caso en que el SDK compartido esta en un disco de solo lectura
# (o sin permisos) y `flutter` falla al escribir en bin/cache. Copia el SDK a
# .tooling/flutter y crea un HOME/PUB_CACHE locales, de modo que ni el SDK del
# sistema ni el HOME del usuario se tocan.
#
# Uso:
#   tool/setup_local_sdk.sh [ruta-al-SDK]
#
# Despues:
#   source .tooling/env.sh
#   tool/build_linux.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SOURCE="${1:-}"
if [[ -z "$SOURCE" ]]; then
  if command -v flutter >/dev/null 2>&1; then
    SOURCE="$(dirname "$(dirname "$(command -v flutter)")")"
  elif [[ -x "${FLUTTER_SDK:-}/bin/flutter" ]]; then
    SOURCE="$FLUTTER_SDK"
  else
    echo "ERROR: indica la ruta del SDK: tool/setup_local_sdk.sh /ruta/a/flutter" >&2
    exit 1
  fi
fi
SOURCE="$(cd "$SOURCE" && pwd)"

if [[ ! -x "$SOURCE/bin/flutter" ]]; then
  echo "ERROR: $SOURCE no parece un SDK de Flutter (falta bin/flutter)." >&2
  exit 1
fi

DEST="$ROOT/.tooling/flutter"
if [[ -x "$DEST/bin/flutter" ]]; then
  echo "Ya existe $DEST; se reutiliza."
else
  echo "Copiando SDK de $SOURCE"
  echo "  -> $DEST (puede ocupar varios GB y tardar unos minutos)"
  mkdir -p "$ROOT/.tooling"
  rsync -a "$SOURCE/" "$DEST/"
fi

mkdir -p "$ROOT/.tooling/home" \
         "$ROOT/.tooling/pub-cache" \
         "$ROOT/.tooling/xdg-cache" \
         "$ROOT/.tooling/xdg-config"

cat > "$ROOT/.tooling/env.sh" <<'ENV'
# Entorno local de Xtreme Studio (generado por tool/setup_local_sdk.sh).
# Calcula la raiz desde este archivo para que siga funcionando si el proyecto
# se mueve o se copia a otro disco.
XS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FLUTTER_BIN="$XS_ROOT/.tooling/flutter/bin/flutter"
export HOME="$XS_ROOT/.tooling/home"
export PUB_CACHE="$XS_ROOT/.tooling/pub-cache"
export XDG_CACHE_HOME="$XS_ROOT/.tooling/xdg-cache"
export XDG_CONFIG_HOME="$XS_ROOT/.tooling/xdg-config"
export PATH="$XS_ROOT/.tooling/flutter/bin:$PATH"
ENV

echo
echo "Listo. Ahora:"
echo "  source .tooling/env.sh"
echo "  tool/build_linux.sh"
