#!/usr/bin/env bash
# Crea un lanzador de escritorio para Xtreme Studio con su icono.
#
# Uso:
#   tool/install_linux_shortcut.sh [ruta-al-bundle]
#
# Por defecto usa build/linux/x64/release/bundle. No necesita sudo: instala el
# .desktop y el icono en el perfil del usuario.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="${1:-$ROOT/build/linux/x64/release/bundle}"
APP="$BUNDLE/xtreme_studio"
ICON_SRC="$BUNDLE/data/app_icon.png"
if [[ ! -x "$APP" ]]; then
  APP="$BUNDLE/xtreme_studio"
fi
if [[ ! -x "$APP" ]]; then
  echo "ERROR: no se encontro el ejecutable en $BUNDLE/xtreme_studio" >&2
  echo "Compila primero con tool/build_linux.sh" >&2
  exit 1
fi
if [[ ! -f "$ICON_SRC" ]]; then
  ICON_SRC="$ROOT/assets/icon/app_icon.png"
fi
if [[ ! -f "$ICON_SRC" ]]; then
  echo "ERROR: no se encontro el icono de la app" >&2
  exit 1
fi

ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
APP_DIR="$HOME/.local/share/applications"
mkdir -p "$ICON_DIR" "$APP_DIR"
cp "$ICON_SRC" "$ICON_DIR/xtreme-studio.png"

DESKTOP="$APP_DIR/xtreme-studio.desktop"
cat > "$DESKTOP" <<DESKTOP_ENTRY
[Desktop Entry]
Type=Application
Version=1.0
Name=Xtreme Studio
GenericName=Consola de emision
Comment=Emision multi-emisora para radio (Icecast2/Shoutcast)
Exec="$APP"
Icon=xtreme-studio
Terminal=false
Categories=AudioVideo;Audio;Mixer;
StartupWMClass=fm.xtreme.xtreme_studio
DESKTOP_ENTRY
chmod 644 "$DESKTOP"

# Actualiza las caches si las herramientas estan disponibles.
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true

echo "Lanzador creado: $DESKTOP"
echo "Icono: $ICON_DIR/xtreme-studio.png"
echo "Ejecutable: $APP"
echo "Busca 'Xtreme Studio' en el menu de aplicaciones."
