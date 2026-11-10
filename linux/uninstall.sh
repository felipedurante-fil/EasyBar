#!/usr/bin/env bash
# Remove o EasyBar instalado por install.sh. Suas configurações e logins ficam
# (apague ~/.config/easybar e ~/.local/share/easybar se quiser tirar tudo).
set -euo pipefail
rm -f "$HOME/.local/bin/easybar" \
      "$HOME/.local/share/applications/easybar.desktop" \
      "$HOME/.local/share/icons/hicolor/256x256/apps/easybar.png" \
      "$HOME/.config/autostart/easybar.desktop"
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
echo "EasyBar removido. Configurações mantidas em ~/.config/easybar e ~/.local/share/easybar."
