# EasyBar

Alternativa gratuita ao [Slidepad](https://slidepad.app) para macOS. Painel lateral deslizante com abas de navegacao web, timer Pomodoro e bloco de notas.

**Versao atual: 1.5**

## Funcionalidades

### Painel lateral
- Janela deslizante que aparece pela borda da tela (direita, esquerda, cima ou baixo)
- Ativacao por atalho de teclado global (padrao: **Option+Q**)
- Dimensoes e posicao configuraveis (porcentagem da tela)
- Efeito frosted glass (material translucido nativo do macOS)

### Abas de navegacao
- Abas com WKWebView integrado (navegacao web completa)
- Favicon automatico via Google Favicons API
- Drag & drop para reordenar abas
- Suspensao de abas para economizar memoria
- Suporte a downloads com pasta configuravel

### Timer Pomodoro
- Opcoes de 5, 10, 15, 20 e 25 minutos
- Contagem regressiva visivel na barra de abas
- Alerta sonoro ao finalizar

### Bloco de notas
- Notas rapidas acessiveis diretamente do painel

### Configuracoes
- Atalho de teclado personalizavel
- Direcao e dimensoes do painel
- Exportar / importar configuracoes (JSON)
- Reset para padroes de fabrica
- Iniciar com o sistema

## Requisitos

- macOS 13 (Ventura) ou superior
- Xcode 15 ou superior

## Como compilar

1. Abra `EasyBar.xcodeproj` no Xcode
2. Configure o Signing com seu Apple ID
3. **Cmd+R** para compilar e rodar

## Como usar

1. O app aparece na barra de menus (icone de sidebar)
2. Pressione **Option+Q** (ou o atalho configurado) para mostrar/ocultar o painel
3. Adicione abas com sites que voce acessa frequentemente
4. Use o menu da barra de menus para acessar configuracoes

## Estrutura

```
EasyBar/
├── EasyBar.swift              — @main, AppDelegate, barra de menus
├── ContentView.swift          — Painel principal com abas e Pomodoro
├── Models.swift               — WebTab, AppSettings, persistencia
├── SlideWindowController.swift — Janela deslizante e hotkey global
├── WebView.swift              — WKWebView wrapper e gerenciador de abas
└── SecondaryViews.swift       — Telas de configuracoes, notas, edicao
```

## Tecnologias

- Swift / SwiftUI
- AppKit (NSStatusBar, NSPanel)
- WebKit (WKWebView)
- Carbon (hotkey global)
- ServiceManagement (login item)

## Creditos

Pensado e editado por Felipe Durante. Codigo base gerado por Manus AI.

## Licenca

Uso pessoal.
