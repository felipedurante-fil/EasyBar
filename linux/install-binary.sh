#!/usr/bin/env bash
# Instala o binário pré-compilado (pacote .tar.gz do GitHub Actions) para o usuário atual.
# Requer só as bibliotecas de execução:  sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0
set -euo pipefail
cd "$(dirname "$0")"
BIN="$HOME/.local/bin"; APPS="$HOME/.local/share/applications"; ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$BIN" "$APPS" "$ICONS"
install -m755 easybar "$BIN/easybar"
install -m644 easybar.png "$ICONS/easybar.png"
sed "s|@EXEC@|$BIN/easybar|g" easybar.desktop > "$APPS/easybar.desktop"
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
update-desktop-database "$APPS" >/dev/null 2>&1 || true
echo "EasyBar instalado em $BIN/easybar — abra pelo menu ou rode: easybar"
