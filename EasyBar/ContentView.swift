import SwiftUI
import UniformTypeIdentifiers
import WebKit
import AppKit

// MARK: - ContentView Principal

struct ContentView: View {
    @ObservedObject var settings:   AppSettings
    var controller: SlideWindowController?

    /// TabManager criado uma única vez, vive enquanto a ContentView existir.
    @StateObject private var tabManager = TabManager()

    /// Histórico de downloads da sessão (para o badge no botão da barra).
    @ObservedObject private var downloads = DownloadsManager.shared

    // MARK: Estados de modais
    @State private var showingAddTab            = false
    @State private var showingSettings          = false
    @State private var showingExitConfirmation  = false
    @State private var showingNotes             = false
    @State private var editingTab:  WebTab?
    @State private var draggedTab:  WebTab?

    // MARK: Estados do Pomodoro
    @State private var showPomodoroMenu         = false
    @State private var pomodoroSecondsLeft:  Int = 0
    @State private var pomodoroTimer: Timer?
    @State private var pomodoroActive           = false
    // CORRIGIDO: armazena a duração selecionada para que o checkmark
    // no menu Pomodoro mostre corretamente qual duração está ativa,
    // em vez de comparar secondsLeft == minutes*60 (verdadeiro só no primeiro segundo).
    @State private var pomodoroSelectedMinutes: Int = 0

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Área de conteúdo web
            // Renderiza apenas a aba selecionada. O TabManager mantém os WKWebViews
            // em cache por UUID, então trocar de aba não recria nem recarrega a página.
            Group {
                if settings.tabs.isEmpty {
                    WelcomeView { showingAddTab = true }
                } else if let selectedId = settings.selectedTabId,
                          let tab = settings.tabs.first(where: { $0.id == selectedId }) {
                    if tab.isSuspended {
                        SuspendedView(tab: tab) { reactivateTab(tab) }
                    } else {
                        ZStack {
                            WebViewWrapper(tab: tab, tabManager: tabManager)
                                // .id(tab.id) garante que o SwiftUI recria o
                                // NSViewRepresentable (chamando makeNSView) cada
                                // vez que a aba selecionada muda — sem isso, SwiftUI
                                // reutiliza o WKWebView da aba anterior e o conteúdo
                                // da nova aba nunca é exibido.
                                .id(tab.id)
                            if tabManager.loadingStates[tab.id] == true {
                                LoadingOverlay()
                            }
                        }
                    }
                } else {
                    // selectedTabId nulo ou inválido — corrige ao aparecer
                    Color.clear
                        .onAppear {
                            settings.selectedTabId = settings.tabs.first?.id
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Linha divisória
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)

            // MARK: Barra de abas
            HStack(spacing: 0) {

                // Botão de ocultar (ícone aponta para o lado de onde a janela veio)
                Button(action: { controller?.hideWindow() }) {
                    Image(systemName: hideIconName())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Ocultar")
                .padding(.leading, 4)

                // Abas com rolagem horizontal
                // .frame(minWidth:0, maxWidth:.infinity) garante que o ScrollView
                // recebe todo o espaço disponível no HStack. Sem isso o Spacer
                // seguinte consome o espaço e o ScrollView fica colapsado.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(settings.tabs) { tab in
                            TabButton(
                                tab: tab,
                                settings: settings,
                                tabManager: tabManager,
                                editingTab: $editingTab
                            )
                            .onDrag {
                                draggedTab = tab
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: TabDropDelegate(
                                    item: tab,
                                    settings: settings,
                                    draggedItem: $draggedTab
                                )
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(minWidth: 0, maxWidth: .infinity)

                // MARK: Botões de ação (direita)
                HStack(spacing: 2) {
                    Button(action: { showingAddTab = true }) {
                        Image(systemName: "plus").frame(width: 28, height: 28)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Adicionar Aba")

                    Button(action: { showingNotes = true }) {
                        Image(systemName: "note.text").frame(width: 28, height: 28)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Bloco de Notas Rápido")

                    Button(action: {
                        AppDelegate.shared?.showDownloadsWindow(activate: true)
                    }) {
                        Image(systemName: "tray.and.arrow.down")
                            .frame(width: 28, height: 28)
                            .overlay(alignment: .topTrailing) {
                                if downloads.activeCount > 0 {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 7, height: 7)
                                        .offset(x: -4, y: 4)
                                }
                            }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Downloads")

                    PomodoroButton(
                        isActive: pomodoroActive,
                        secondsLeft: pomodoroSecondsLeft,
                        selectedMinutes: pomodoroSelectedMinutes,
                        showMenu: $showPomodoroMenu
                    ) { minutes in
                        startPomodoro(minutes: minutes)
                    } onCancel: {
                        cancelPomodoro()
                    }

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape").frame(width: 28, height: 28)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Configurações")

                    Button(action: { showingExitConfirmation = true }) {
                        Image(systemName: "power")
                            .foregroundColor(.red)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Sair")
                }
                .padding(.trailing, 6)
            }
            .frame(height: 44)
            .background(.bar)
        }
        // Efeito frosted glass via SwiftUI material.
        // IMPORTANTE: NÃO usar .clipShape aqui — ele adiciona uma CALayer mask
        // ao NSHostingView que interfere com o pipeline de composição do WKWebView
        // no macOS 26, causando a área de conteúdo ficar em branco.
        // O arredondamento visual é feito apenas via overlay sem mask layer.
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )

        // MARK: Sheets
        .sheet(isPresented: $showingAddTab) {
            AddTabWindow(settings: settings, tabManager: tabManager)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsWindow(settings: settings, controller: controller)
        }
        .sheet(isPresented: $showingNotes) {
            NotesWindow()
        }
        .sheet(item: $editingTab) { tab in
            EditTabWindow(settings: settings, tab: tab, tabManager: tabManager)
        }

        // MARK: Ciclo de vida
        .onAppear {
            tabManager.settings = settings
            // Garante que sempre há uma aba selecionada ao abrir
            if settings.selectedTabId == nil ||
               !settings.tabs.contains(where: { $0.id == settings.selectedTabId }) {
                settings.selectedTabId = settings.tabs.first?.id
            }
        }

        // MARK: Captura de metadados ao terminar de carregar
        .onReceive(
            NotificationCenter.default.publisher(for: NSNotification.Name("WebPageLoaded"))
        ) { notification in
            guard let webView = notification.object as? WKWebView,
                  let tabId   = notification.userInfo?["tabId"] as? UUID else { return }
            captureMetadata(from: webView, tabId: tabId)
        }

        // MARK: Confirmação de saída
        .alert(isPresented: $showingExitConfirmation) {
            Alert(
                title: Text("Sair do Programa"),
                message: Text("Deseja encerrar o EasyBar?"),
                primaryButton: .destructive(Text("Sair")) {
                    NSApplication.shared.terminate(nil)
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }

    // MARK: - Pomodoro

    func startPomodoro(minutes: Int) {
        cancelPomodoro()
        pomodoroSecondsLeft     = minutes * 60
        pomodoroActive          = true
        pomodoroSelectedMinutes = minutes
        // RunLoop.main garante disparo mesmo durante scroll/drag
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            if pomodoroSecondsLeft > 0 {
                pomodoroSecondsLeft -= 1
            } else {
                cancelPomodoro()
                sendPomodoroAlert()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pomodoroTimer = timer
    }

    func cancelPomodoro() {
        pomodoroTimer?.invalidate()
        pomodoroTimer           = nil
        pomodoroActive          = false
        pomodoroSecondsLeft     = 0
        pomodoroSelectedMinutes = 0
    }

    func sendPomodoroAlert() {
        let alert = NSAlert()
        alert.messageText     = "Pomodoro Concluído!"
        alert.informativeText = "Seu tempo de foco terminou. Hora de fazer uma pausa!"
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "OK")
        NSSound.beep()
        alert.runModal()
    }

    // MARK: - Helpers

    func reactivateTab(_ tab: WebTab) {
        guard let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        settings.tabs[index].isSuspended = false
        settings.selectedTabId           = tab.id
        _ = tabManager.getWebView(for: settings.tabs[index])
    }

    func hideIconName() -> String {
        switch settings.direction {
        case .leftToRight:  return "chevron.left.2"
        case .rightToLeft:  return "chevron.right.2"
        case .topToBottom:  return "chevron.up.2"
        case .bottomToTop:  return "chevron.down.2"
        }
    }

    /// Captura título e favicon da página carregada e atualiza a aba correspondente.
    func captureMetadata(from webView: WKWebView, tabId: UUID) {
        guard let index = settings.tabs.firstIndex(where: { $0.id == tabId }) else { return }

        // CORRIGIDO: título atualizado sempre que a página fornecer um título válido,
        // não apenas quando o título atual era "Carregando..." ou vazio.
        // O comportamento anterior impedia a atualização após navegação interna
        // (ex: google.com → google.com/maps mantinha o título da primeira página).
        let pageTitle = webView.title ?? ""
        if !pageTitle.isEmpty {
            settings.tabs[index].title = pageTitle
        }

        // Favicon via API do Google — apenas se ainda não tem ícone e não foi tentado antes
        if settings.tabs[index].faviconData == nil,
           !tabManager.faviconAttempted.contains(tabId),
           let host = webView.url?.host {
            tabManager.faviconAttempted.insert(tabId)
            let googleURL = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")!
            // ContentView é uma struct — capturamos settings (referência) diretamente
            let settingsRef = settings
            URLSession.shared.dataTask(with: googleURL) { data, _, _ in
                guard let data = data, data.count > 500 else { return }
                DispatchQueue.main.async {
                    if let i = settingsRef.tabs.firstIndex(where: { $0.id == tabId }) {
                        settingsRef.tabs[i].faviconData = data
                    }
                }
            }.resume()
        }
    }
}

// MARK: - Tela de Boas-Vindas

struct WelcomeView: View {
    let onAddTab: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 20)

                Image(systemName: "sidebar.left")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)

                Text("EasyBar")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("""
EasyBar é uma alternativa gratuita ao Slidepad. \
Adicione abas que acessam sites de forma rápida, sem precisar abrir o navegador. \
Fiz o aplicativo de acordo com minhas necessidades. Adicionei algumas outras funções. \
Espero que seja útil para você =)

Pensado e editado por Felipe Durante. \
O código base foi gerado pelo Manus.
""")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)

                Button(action: onAddTab) {
                    Label("Adicionar Primeira Aba", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Botão Pomodoro

struct PomodoroButton: View {
    let isActive:         Bool
    let secondsLeft:      Int
    // CORRIGIDO: recebe a duração selecionada diretamente para exibir
    // o checkmark correto no menu, em vez de comparar secondsLeft == minutes*60
    // (que era verdadeiro apenas no primeiro segundo de cada sessão).
    let selectedMinutes:  Int
    @Binding var showMenu: Bool
    let onStart:  (Int) -> Void
    let onCancel: () -> Void

    private let options = [25, 20, 15, 10, 5]

    var timeLabel: String {
        guard isActive && secondsLeft > 0 else { return "" }
        let m = secondsLeft / 60
        let s = secondsLeft % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        Button(action: { showMenu.toggle() }) {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .foregroundColor(isActive ? .orange : .primary)
                    .frame(width: 20, height: 20)
                if isActive && !timeLabel.isEmpty {
                    Text(timeLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                        .frame(minWidth: 32)
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 4)
        }
        .buttonStyle(PlainButtonStyle())
        .help(isActive ? "Pomodoro: \(timeLabel) restantes" : "Iniciar Pomodoro")
        .popover(isPresented: $showMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Pomodoro")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                Divider()

                ForEach(options, id: \.self) { minutes in
                    Button(action: {
                        onStart(minutes)
                        showMenu = false
                    }) {
                        HStack {
                            Image(systemName: "timer")
                                .foregroundColor(.orange)
                                .frame(width: 16)
                            Text("\(minutes) minutos")
                            Spacer()
                            // CORRIGIDO: usa selectedMinutes para o checkmark
                            if isActive && selectedMinutes == minutes {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if isActive {
                    Divider()
                    Button(action: {
                        onCancel()
                        showMenu = false
                    }) {
                        HStack {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.red)
                                .frame(width: 16)
                            Text("Cancelar Pomodoro")
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Spacer(minLength: 6)
            }
            .frame(width: 180)
        }
    }
}

// MARK: - Overlay de Carregamento

struct LoadingOverlay: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Carregando...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
    }
}

// MARK: - Botão de Aba

struct TabButton: View {
    let tab:        WebTab
    @ObservedObject var settings:   AppSettings
    @ObservedObject var tabManager: TabManager
    @Binding var editingTab: WebTab?

    var isSelected: Bool { settings.selectedTabId == tab.id }

    /// Rótulo curto exibido abaixo do ícone (máx. 8 caracteres).
    var shortTitle: String {
        let t = tab.title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty && t != "Carregando..." else { return "..." }
        guard t.count > 8 else { return t }
        return String(t.prefix(7)) + "\u{2026}"
    }

    var body: some View {
        Button(action: {
            settings.selectedTabId = tab.id
            if tab.isSuspended,
               let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) {
                settings.tabs[index].isSuspended = false
                _ = tabManager.getWebView(for: settings.tabs[index])
            }
        }) {
            VStack(spacing: 2) {
                ZStack {
                    tab.getIcon()
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)

                    if tab.isSuspended {
                        Color.black.opacity(0.4)
                            .frame(width: 22, height: 22)
                            .cornerRadius(4)
                        Image(systemName: "pause.circle.fill")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.system(size: 10))
                    }
                }

                Text(shortTitle)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 52)
            }
            .frame(width: 54, height: 40)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help(tab.title)
        .contextMenu {
            Button("Recarregar") {
                if let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) {
                    settings.tabs[index].isSuspended = false
                }
                settings.selectedTabId = tab.id
                tabManager.reloadOriginalURL(for: tab)
            }

            Button("Atualizar Ícone e Metadados") {
                if let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) {
                    settings.tabs[index].title       = "Carregando..."
                    settings.tabs[index].faviconData = nil
                    settings.tabs[index].isSuspended = false
                }
                // CORRIGIDO: remove o tabId de faviconAttempted para permitir
                // que o favicon seja rebuscado. Sem isso, o guard em captureMetadata
                // bloqueava a requisição mesmo após o usuário pedir explicitamente.
                tabManager.faviconAttempted.remove(tab.id)
                settings.selectedTabId = tab.id
                tabManager.reloadOriginalURL(for: tab)
            }

            Button("Renomear / Editar") { editingTab = tab }

            Divider()

            if tab.isSuspended {
                Button("Reativar Aba") {
                    if let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) {
                        settings.tabs[index].isSuspended = false
                        settings.selectedTabId = tab.id
                        _ = tabManager.getWebView(for: settings.tabs[index])
                    }
                }
            } else {
                Button("Suspender Aba") {
                    if let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) {
                        settings.tabs[index].isSuspended = true
                        tabManager.suspendTab(tab.id)
                    }
                }
            }

            Divider()

            Button("Remover Aba", role: .destructive) {
                tabManager.suspendTab(tab.id)
                settings.tabs.removeAll(where: { $0.id == tab.id })
                if settings.selectedTabId == tab.id {
                    settings.selectedTabId = settings.tabs.first?.id
                }
            }
        }
    }
}

// MARK: - Tela de Aba Suspensa

struct SuspendedView: View {
    let tab:          WebTab
    let onReactivate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            tab.getIcon()
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .opacity(0.5)

            Text(tab.title)
                .font(.headline)

            Text("Esta aba está suspensa para economizar memória.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Recarregar Aba", action: onReactivate)
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Delegate para Drag & Drop de Abas

struct TabDropDelegate: DropDelegate {
    let item: WebTab
    @ObservedObject var settings: AppSettings
    @Binding var draggedItem: WebTab?

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem, dragged != item else { return }
        guard let from = settings.tabs.firstIndex(of: dragged),
              let to   = settings.tabs.firstIndex(of: item) else { return }
        withAnimation {
            settings.tabs.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: to > from ? to + 1 : to
            )
        }
    }
}

// MARK: - Visual Effect View (fundo translúcido nativo do macOS)

struct AppVisualEffectView: NSViewRepresentable {
    let material:     NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material     = material
        view.blendingMode = blendingMode
        view.state        = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material     = material
        nsView.blendingMode = blendingMode
    }
}
