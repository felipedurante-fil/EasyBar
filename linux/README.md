# EasyBar para Linux

Painel deslizante com abas web (WhatsApp, Gemini, ChatGPT…), igual ao EasyBar do Mac —
em **Rust + GTK3 + WebKitGTK**. Feito para o **Linux Mint (Cinnamon, sessão X11)**.

> Feito em vibe coding (Felipe Durante e Claude) e revisado por Felipe Durante.

## Instalar (compilando)

```bash
sudo apt install build-essential pkg-config curl \
                 libgtk-3-dev libwebkit2gtk-4.1-dev \
                 gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # só se ainda não tem Rust; reabra o terminal depois
cd linux
./install.sh
```

Funciona no Mint 21.x e 22.x (ambos têm `libwebkit2gtk-4.1`). O `install.sh` não usa sudo:
instala em `~/.local/bin`, adiciona o ícone e o item **EasyBar** no menu.

### Instalar sem compilar (binário do GitHub Actions)

Baixe o artefato `easybar-linux-x86_64` da aba **Actions** do repositório, e:

```bash
sudo apt install libgtk-3-0 libwebkit2gtk-4.1-0
tar xzf easybar-linux-x86_64.tar.gz && cd easybar-linux-x86_64 && ./install-binary.sh
```

## Trazer suas configurações do Mac

1. No Mac, no EasyBar: **Configurações → Exportar** → salva um arquivo `.json`.
2. Leve o arquivo ao Linux (e-mail, pendrive, nuvem…).
3. No Linux, ao abrir pela primeira vez, clique **Importar backup do Mac…**
   (ou depois: ⚙︎ **Configurações → Importar backup do Mac…**).

Vêm junto: abas (nome, endereço, ícone, política de descarregamento por aba), direção,
tamanho/posição do painel, atalho (traduzido: Option→Alt, Command→Super) e a preferência de
descarregamento automático.

**Não migram** (o macOS e o Linux guardam isso de formas incompatíveis, e é por segurança):
logins, cookies, sessões. Entre de novo em cada site — no WhatsApp Web, leia o QR outra vez.

## Uso

| O quê | Como |
|---|---|
| Mostrar/ocultar | atalho global (padrão **Alt+Q**), clique no ícone da bandeja, ou o botão ▶ da barra |
| Atalho alternativo | no Cinnamon: *Menu → Teclado → Atalhos → Personalizados* → comando `easybar --toggle` |
| Trocar de aba | clique no ícone; **botão direito** na aba: recarregar, descarregar, política automática, editar, remover |
| Nova aba | botão **+** |
| Downloads | vão para `~/Downloads/EasyBar` (mude em Configurações); botão de pasta abre o histórico |
| Início automático | Configurações → *Abrir ao iniciar a sessão* |

Parâmetros: `easybar --toggle` (alterna a instância já aberta), `easybar --background` (abre sem mostrar o painel).

## Diferenças em relação ao Mac

- Sessão **X11** (o padrão do Cinnamon). Em Wayland o app roda via XWayland, mas o atalho global e o recorte do deslize podem não funcionar.
- O deslize mantém a janela sempre dentro do monitor e mostra só a fatia visível (o Cinnamon não deixa janelas ficarem fora da tela); a animação acompanha o relógio de quadros do monitor.
- O atalho global é configurado em texto (`Alt+Q`, `Ctrl+Shift+E`, `Super+Space`…).
- Ainda **não** há: Notas, Pomodoro, reordenar abas por arrastar.

## Problemas

Rode pelo terminal para ver as mensagens: `easybar` (ele registra cada abrir/fechar do painel, o atalho global e a bandeja). Ao reportar um erro, envie:
a saída do terminal, `lsb_release -a`, `echo $XDG_SESSION_TYPE`, `echo $XDG_CURRENT_DESKTOP`
e o que você fez antes.

- **Páginas em branco/piscando** (alguns drivers de vídeo): `WEBKIT_DISABLE_DMABUF_RENDERER=1 easybar`
  (ou `WEBKIT_DISABLE_COMPOSITING_MODE=1 easybar`).
- **Sem áudio/vídeo**: instale os plugins GStreamer listados acima.
- **Atalho não funciona**: outro programa já usa a combinação — troque em Configurações, ou use `easybar --toggle` como atalho do sistema.

## Desenvolvimento

```bash
cd linux
cargo test -p easybar-core    # lógica pura: backup, atalhos, geometria, políticas, URLs
cargo build --release -p easybar
```

`core/` = lógica sem GUI (testada em qualquer sistema). `app/` = GTK3/WebKitGTK.
