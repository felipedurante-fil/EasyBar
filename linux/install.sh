#!/usr/bin/env bash
# Compila e instala o EasyBar para o usuário atual (sem sudo, em ~/.local).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust não encontrado. Instale com:"
  echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  echo "e abra um novo terminal."
  exit 1
fi

if ! pkg-config --exists gtk+-3.0 webkit2gtk-4.1 2>/dev/null; then
  echo "Faltam bibliotecas de desenvolvimento. Instale com:"
  echo "  sudo apt install build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev"
  exit 1
fi

echo "==> Compilando (a primeira vez demora alguns minutos)…"
cargo build --release -p easybar

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
ICONS="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$BIN" "$APPS" "$ICONS"

install -m755 target/release/easybar "$BIN/easybar"
install -m644 assets/easybar.png "$ICONS/easybar.png"
sed "s|@EXEC@|$BIN/easybar|g" assets/easybar.desktop > "$APPS/easybar.desktop"
chmod 644 "$APPS/easybar.desktop"

gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
update-desktop-database "$APPS" >/dev/null 2>&1 || true

echo
echo "Pronto! Instalado em $BIN/easybar"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "Aviso: $BIN não está no PATH desta sessão (o menu de aplicativos funciona mesmo assim)." ;;
esac
echo "Abra pelo menu (EasyBar) ou rode: easybar"
