import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Modelo de Sugestao de Site

struct SiteSuggestion: Identifiable {
    let id = UUID()
    let name:        String
    let url:         String
    let icon:        String   // Emoji
    let description: String
}

struct SuggestionCategory: Identifiable {
    let id = UUID()
    let name:  String
    let icon:  String   // SF Symbol
    let sites: [SiteSuggestion]
}

// MARK: - Catalogo de Sugestoes

let siteSuggestionCatalog: [SuggestionCategory] = [
    SuggestionCategory(name: "Comunicação", icon: "message.fill", sites: [
        SiteSuggestion(name: "WhatsApp Web",  url: "https://web.whatsapp.com",      icon: "📱", description: "Mensagens sem trocar de janela"),
        SiteSuggestion(name: "Telegram Web",  url: "https://web.telegram.org",      icon: "✈️", description: "Sincronização rápida entre dispositivos"),
        SiteSuggestion(name: "Discord",       url: "https://discord.com/app",       icon: "🎮", description: "Comunidades e chat de voz"),
        SiteSuggestion(name: "Slack",         url: "https://app.slack.com",         icon: "💼", description: "Comunicação corporativa"),
        SiteSuggestion(name: "Gmail",         url: "https://mail.google.com",       icon: "📧", description: "E-mail do Google"),
        SiteSuggestion(name: "Outlook",       url: "https://outlook.live.com",      icon: "📨", description: "E-mail da Microsoft"),
    ]),
    SuggestionCategory(name: "Inteligência Artificial", icon: "brain.head.profile", sites: [
        SiteSuggestion(name: "ChatGPT",       url: "https://chatgpt.com",           icon: "🤖", description: "Assistente de IA da OpenAI"),
        SiteSuggestion(name: "Claude",        url: "https://claude.ai",             icon: "🧠", description: "Assistente de IA da Anthropic"),
        SiteSuggestion(name: "Gemini",        url: "https://gemini.google.com",     icon: "✨", description: "IA do Google"),
        SiteSuggestion(name: "Perplexity AI", url: "https://perplexity.ai",         icon: "🔍", description: "Pesquisa com fontes citadas"),
        SiteSuggestion(name: "Manus AI",      url: "https://manus.ai",              icon: "🦾", description: "Agente de IA autônomo"),
        SiteSuggestion(name: "Phind",         url: "https://phind.com",             icon: "💻", description: "Busca focada em programação"),
        SiteSuggestion(name: "Hugging Face",  url: "https://huggingface.co/chat",   icon: "🤗", description: "Modelos open-source (Llama, Mistral)"),
        SiteSuggestion(name: "You.com",       url: "https://you.com",               icon: "🔎", description: "Buscador com IA integrada"),
        SiteSuggestion(name: "Blackbox AI",   url: "https://blackbox.ai",           icon: "📦", description: "OCR de código em imagens e vídeos"),
    ]),
    SuggestionCategory(name: "Tradução e Escrita", icon: "textformat.abc", sites: [
        SiteSuggestion(name: "DeepL",          url: "https://deepl.com/translator", icon: "🌐", description: "Tradução de alta qualidade"),
        SiteSuggestion(name: "DeepL Write",    url: "https://deepl.com/write",      icon: "✍️", description: "Melhora gramática e estilo"),
        SiteSuggestion(name: "Google Tradutor",url: "https://translate.google.com", icon: "🔤", description: "Traduções rápidas"),
        SiteSuggestion(name: "LanguageTool",   url: "https://languagetool.org",     icon: "📝", description: "Revisão gramatical open-source"),
    ]),
    SuggestionCategory(name: "Produtividade e Tarefas", icon: "checklist", sites: [
        SiteSuggestion(name: "Notion",          url: "https://notion.so",                icon: "📓", description: "Notas, tarefas e banco de dados"),
        SiteSuggestion(name: "TickTick",        url: "https://ticktick.com/webapp",      icon: "✅", description: "Gerenciador de tarefas e Pomodoro"),
        SiteSuggestion(name: "Microsoft To Do", url: "https://to-do.microsoft.com/tasks",icon: "☑️", description: "Listas de tarefas da Microsoft"),
        SiteSuggestion(name: "Todoist",         url: "https://todoist.com/app",          icon: "📋", description: "Gerenciador de tarefas avançado"),
        SiteSuggestion(name: "Google Keep",     url: "https://keep.google.com",          icon: "📌", description: "Notas e lembretes rápidos"),
        SiteSuggestion(name: "Trello",          url: "https://trello.com",               icon: "🗂️", description: "Quadros Kanban"),
        SiteSuggestion(name: "Google Calendar", url: "https://calendar.google.com",      icon: "📅", description: "Agenda e reuniões"),
        SiteSuggestion(name: "Pomofocus",       url: "https://pomofocus.io",             icon: "⏱️", description: "Timer Pomodoro na lateral"),
        SiteSuggestion(name: "Linear",          url: "https://linear.app",               icon: "🚀", description: "Gestão de projetos para times de produto"),
    ]),
    SuggestionCategory(name: "Entretenimento e Áudio", icon: "music.note", sites: [
        SiteSuggestion(name: "Spotify Web",   url: "https://open.spotify.com",      icon: "🎵", description: "Controle de música sem app pesado"),
        SiteSuggestion(name: "YouTube Music", url: "https://music.youtube.com",     icon: "▶️", description: "Alternativa leve do Google"),
        SiteSuggestion(name: "Pocket Casts",  url: "https://play.pocketcasts.com",  icon: "🎙️", description: "Gerenciar podcasts"),
        SiteSuggestion(name: "Lofi.co",       url: "https://lofi.co",               icon: "🎧", description: "Sons para concentração"),
        SiteSuggestion(name: "Brain.fm",      url: "https://brain.fm",              icon: "🧘", description: "Música para foco e produtividade"),
    ]),
    SuggestionCategory(name: "Desenvolvimento", icon: "chevron.left.forwardslash.chevron.right", sites: [
        SiteSuggestion(name: "GitHub",         url: "https://github.com",              icon: "🐙", description: "Notificações e pull requests"),
        SiteSuggestion(name: "Stack Overflow", url: "https://stackoverflow.com",       icon: "📚", description: "Consultas rápidas de sintaxe"),
        SiteSuggestion(name: "DevDocs.io",     url: "https://devdocs.io",              icon: "📖", description: "Documentações reunidas em um lugar"),
        SiteSuggestion(name: "JSON Hero",      url: "https://jsonhero.io",             icon: "🗂️", description: "Visualizador interativo de JSON"),
        SiteSuggestion(name: "Explainshell",   url: "https://explainshell.com",        icon: "🖥️", description: "Explica comandos de terminal"),
        SiteSuggestion(name: "Vercel",         url: "https://vercel.com/dashboard",    icon: "▲",  description: "Dashboard de deploys"),
        SiteSuggestion(name: "Netlify",        url: "https://app.netlify.com",         icon: "🌿", description: "Monitorar deploys e sites"),
        SiteSuggestion(name: "CyberChef",      url: "https://gchq.github.io/CyberChef",icon: "🔧", description: "Canivete suíço da web (Base64, timestamps...)"),
    ]),
    SuggestionCategory(name: "Utilitários de Arquivo", icon: "doc.fill", sites: [
        SiteSuggestion(name: "Stirling PDF",  url: "https://stirlingpdf.io",        icon: "📄", description: "Editor de PDF open-source"),
        SiteSuggestion(name: "Excalidraw",    url: "https://excalidraw.com",        icon: "✏️", description: "Esboços e diagramas no estilo mão"),
        SiteSuggestion(name: "Squoosh",       url: "https://squoosh.app",           icon: "🖼️", description: "Compressão de imagens do Google"),
        SiteSuggestion(name: "CloudConvert",  url: "https://cloudconvert.com",      icon: "☁️", description: "Converte quase todos os formatos"),
        SiteSuggestion(name: "TinyPNG",       url: "https://tinypng.com",           icon: "🐼", description: "Otimiza imagens PNG e JPEG"),
        SiteSuggestion(name: "Remove.bg",     url: "https://remove.bg",             icon: "🪄", description: "Remove fundo de imagens"),
        SiteSuggestion(name: "Convertio",     url: "https://convertio.co",          icon: "🔄", description: "Conversor de arquivos online"),
    ]),
    SuggestionCategory(name: "Pesquisa e Referência", icon: "magnifyingglass", sites: [
        SiteSuggestion(name: "Google Scholar", url: "https://scholar.google.com",   icon: "🎓", description: "Artigos e publicações acadêmicas"),
        SiteSuggestion(name: "Sci-Hub",        url: "https://sci-hub.se",           icon: "🔓", description: "Acesso a artigos científicos"),
        SiteSuggestion(name: "LibGen",         url: "https://libgen.is",            icon: "📚", description: "Biblioteca de livros e artigos"),
        SiteSuggestion(name: "Wikipedia",      url: "https://wikipedia.org",        icon: "🌍", description: "Enciclopédia colaborativa"),
        SiteSuggestion(name: "Wolfram Alpha",  url: "https://wolframalpha.com",     icon: "🧮", description: "Motor de conhecimento computacional"),
    ]),
    SuggestionCategory(name: "Privacidade e Segurança", icon: "lock.shield.fill", sites: [
        SiteSuggestion(name: "Bitwarden",         url: "https://vault.bitwarden.com",  icon: "🔐", description: "Gerenciador de senhas open-source"),
        SiteSuggestion(name: "Temp Mail",         url: "https://temp-mail.org",        icon: "📬", description: "E-mail temporário para testes"),
        SiteSuggestion(name: "Have I Been Pwned", url: "https://haveibeenpwned.com",   icon: "🛡️", description: "Verifica vazamentos de dados"),
        SiteSuggestion(name: "ProtonMail",        url: "https://mail.proton.me",       icon: "🔒", description: "E-mail criptografado"),
    ]),
    SuggestionCategory(name: "Redes Sociais", icon: "person.2.fill", sites: [
        SiteSuggestion(name: "Instagram",  url: "https://instagram.com",        icon: "📸", description: "Feed e DMs"),
        SiteSuggestion(name: "Twitter / X",url: "https://x.com",               icon: "🐦", description: "Acompanhar tendências"),
        SiteSuggestion(name: "Reddit",     url: "https://reddit.com",          icon: "🤖", description: "Comunidades e discussões"),
        SiteSuggestion(name: "Buffer",     url: "https://app.buffer.com",      icon: "📆", description: "Agendamento de posts"),
    ]),
    SuggestionCategory(name: "Utilitários Rápidos", icon: "bolt.fill", sites: [
        SiteSuggestion(name: "World Time Buddy", url: "https://worldtimebuddy.com",  icon: "🕐", description: "Fusos horários para equipes remotas"),
        SiteSuggestion(name: "Speedtest",        url: "https://speedtest.net",       icon: "📶", description: "Teste de velocidade de internet"),
        SiteSuggestion(name: "DownDetector",     url: "https://downdetector.com",    icon: "🚨", description: "Verifica se um serviço está fora do ar"),
        SiteSuggestion(name: "Bundlephobia",     url: "https://bundlephobia.com",    icon: "📦", description: "Impacto de bibliotecas npm no projeto"),
        SiteSuggestion(name: "Wallabag",         url: "https://app.wallabag.it",     icon: "📰", description: "Salvar artigos para ler depois"),
    ]),
]

// MARK: - Adicionar Nova Aba (com Sugestoes e busca)

struct AddTabWindow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var tabManager: TabManager
    @Environment(\.presentationMode) var presentationMode

    @State private var urlString:     String = ""
    @State private var searchText:    String = ""

    var filteredCategories: [SuggestionCategory] {
        if searchText.isEmpty { return siteSuggestionCatalog }
        return siteSuggestionCatalog.compactMap { cat in
            let filtered = cat.sites.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.url.localizedCaseInsensitiveContains(searchText)
            }
            return filtered.isEmpty ? nil : SuggestionCategory(name: cat.name, icon: cat.icon, sites: filtered)
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // Cabecalho
            VStack(spacing: 12) {
                Text("Adicionar Nova Aba")
                    .font(.headline)
                    .padding(.top, 20)

                // Campo de URL do site
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                    TextField("Endereço (ex: google.com, 192.168.1.1)", text: $urlString)
                        .textFieldStyle(PlainTextFieldStyle())
                        .onSubmit {
                            if !urlString.trimmingCharacters(in: .whitespaces).isEmpty {
                                addTab(url: urlString)
                            }
                        }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 20)

                // Botoes principais
                HStack {
                    Button("Cancelar") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.secondary)
                    Spacer()
                    Button("Adicionar") {
                        addTab(url: urlString)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).count < 3)
                }
                .padding(.horizontal, 20)

                Divider()

                // Cabecalho das sugestoes com busca
                HStack {
                    Text("Sugestões de Sites")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Buscar...", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .frame(width: 130)
                            .font(.caption)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            // Lista de sugestoes por categoria
            ScrollView {
                if filteredCategories.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("Nenhum site encontrado para \"\(searchText)\"")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(filteredCategories) { category in
                            Section(header: CategoryHeader(category: category)) {
                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: 8),
                                        GridItem(.flexible(), spacing: 8),
                                        GridItem(.flexible(), spacing: 8)
                                    ],
                                    spacing: 8
                                ) {
                                    ForEach(category.sites) { site in
                                        SuggestionCard(site: site) {
                                            addTab(url: site.url)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 620, height: 720)
    }

    // MARK: - Helpers

    func addTab(url raw: String) {
        var raw = raw.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }

        if !raw.contains("://") {
            // Usa a função centralizada isLocalNetworkAddress de WebView.swift
            let host = raw.split(separator: "/").first.map(String.init) ?? raw
            raw = (isLocalNetworkAddress(host) ? "http://" : "https://") + raw
        }

        guard let url = URL(string: raw) else { return }

        let newTab = WebTab(title: "Carregando...", url: url)
        settings.tabs.append(newTab)
        settings.selectedTabId = newTab.id
        _ = tabManager.getWebView(for: newTab)

        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Cabecalho de Categoria

struct CategoryHeader: View {
    let category: SuggestionCategory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.caption)
                .foregroundColor(.accentColor)
            Text(category.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Card de Sugestao

struct SuggestionCard: View {
    let site:  SiteSuggestion
    let onAdd: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onAdd) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(site.icon)
                        .font(.title3)
                    Text(site.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .opacity(isHovered ? 1 : 0.4)
                }
                Text(site.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovered ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help("Adicionar \(site.name): \(site.url)")
    }
}

// MARK: - Editar Aba Existente

struct EditTabWindow: View {
    @ObservedObject var settings: AppSettings
    let tab: WebTab
    @ObservedObject var tabManager: TabManager
    @Environment(\.presentationMode) var presentationMode

    @State private var title:            String
    @State private var urlString:        String
    @State private var selectedIconData: Data?
    @State private var iconURLString:    String = ""
    @State private var isLoadingIcon:    Bool   = false
    @State private var showingFilePicker = false

    init(settings: AppSettings, tab: WebTab, tabManager: TabManager) {
        self.settings   = settings
        self.tab        = tab
        self.tabManager = tabManager
        _title            = State(initialValue: tab.title)
        _urlString        = State(initialValue: tab.url.absoluteString)
        _selectedIconData = State(initialValue: tab.faviconData)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Editar Aba")
                .font(.headline)
                .padding(.top)

            // Preview e seletor de icone
            VStack(spacing: 8) {
                Group {
                    if let data = selectedIconData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "globe")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 64, height: 64)
                .cornerRadius(8)

                // Opcao 1: escolher arquivo local
                Button("Escolher Arquivo de Imagem") {
                    showingFilePicker = true
                }
                .fileImporter(
                    isPresented: $showingFilePicker,
                    allowedContentTypes: [.png, .jpeg, .gif, .bmp, .tiff],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        if url.startAccessingSecurityScopedResource() {
                            defer { url.stopAccessingSecurityScopedResource() }
                            selectedIconData = try? Data(contentsOf: url)
                        }
                    }
                }

                // Opcao 2: colar URL da imagem
                HStack(spacing: 6) {
                    TextField("Ou cole a URL de uma imagem...", text: $iconURLString)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.caption)

                    Button("Carregar") {
                        loadIconFromURL(iconURLString)
                    }
                    .disabled(iconURLString.trimmingCharacters(in: .whitespaces).isEmpty)
                    .font(.caption)

                    if isLoadingIcon {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 4)

                // Opcao 3: colar imagem do clipboard (Cmd+V ou botao)
                Button(action: pasteIconFromClipboard) {
                    Label("Colar Imagem (Clipboard)", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .help("Cola a imagem copiada (Cmd+C em qualquer lugar) como ícone da aba")

                if selectedIconData != nil {
                    Button("Remover Ícone Personalizado") {
                        selectedIconData = nil
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)

            Form {
                TextField("Nome:", text: $title)
                TextField("URL:", text: $urlString)
            }
            .padding(.horizontal)

            HStack {
                Button("Cancelar") {
                    presentationMode.wrappedValue.dismiss()
                }
                Spacer()
                Button("Salvar") {
                    saveChanges()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460)
        .padding(.bottom)
    }

    /// Cola a imagem que estiver no clipboard do sistema como icone da aba.
    func pasteIconFromClipboard() {
        let pb = NSPasteboard.general
        // Tenta obter como NSImage diretamente
        if let img = NSImage(pasteboard: pb) {
            if let tiff = img.tiffRepresentation,
               let rep  = NSBitmapImageRep(data: tiff),
               let png  = rep.representation(using: .png, properties: [:]) {
                selectedIconData = png
                return
            }
        }
        // Fallback: tenta obter como Data de imagem
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType(rawValue: "public.jpeg"),
            NSPasteboard.PasteboardType(rawValue: "public.png")
        ]
        for type in imageTypes {
            if let data = pb.data(forType: type), NSImage(data: data) != nil {
                selectedIconData = data
                return
            }
        }
    }

    func loadIconFromURL(_ urlStr: String) {
        let trimmed = urlStr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed) else { return }

        isLoadingIcon = true
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                self.isLoadingIcon = false
                if let data = data, NSImage(data: data) != nil {
                    self.selectedIconData = data
                }
            }
        }.resume()
    }

    func saveChanges() {
        guard let index = settings.tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        var raw = urlString.trimmingCharacters(in: .whitespaces)
        if !raw.contains("://") {
            let host = raw.split(separator: "/").first.map(String.init) ?? raw
            raw = (isLocalNetworkAddress(host) ? "http://" : "https://") + raw
        }

        guard let url = URL(string: raw) else { return }

        settings.tabs[index].title       = title
        settings.tabs[index].url         = url
        settings.tabs[index].faviconData = selectedIconData

        if url != tab.url {
            tabManager.suspendTab(tab.id)
            settings.tabs[index].isSuspended = false
            _ = tabManager.getWebView(for: settings.tabs[index])
        }

        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Configuracoes

struct SettingsWindow: View {
    @ObservedObject var settings: AppSettings
    var controller: SlideWindowController?
    @Environment(\.presentationMode) var presentationMode

    @State private var isListeningForHotKey  = false
    @State private var localWidthPct:  Double = 0.70
    @State private var localHeightPct: Double = 0.80
    @State private var localOffsetPct: Double = 0.10
    @State private var localDirection: WindowDirection = .rightToLeft
    @State private var exportError:    String? = nil
    @State private var importError:    String? = nil
    @State private var showImportOK    = false
    @State private var downloadFolderChanged = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Configurações")
                .font(.headline)
                .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Geral
                    GroupBox(label: Text("Geral").bold()) {
                        VStack(alignment: .leading, spacing: 12) {
                            // CORRIGIDO: .onChange(of: settings.launchAtLogin) removido —
                            // causava double-save junto com o debounce de 500ms do auto-save.
                            Toggle("Iniciar com o Sistema", isOn: $settings.launchAtLogin)

                            Picker("Direção do Deslizamento:", selection: $localDirection) {
                                ForEach(WindowDirection.allCases, id: \.self) { dir in
                                    Text(dir.rawValue).tag(dir)
                                }
                            }
                        }
                        .padding(8)
                    }

                    // Downloads
                    GroupBox(label: Text("Downloads").bold()) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Pasta onde os arquivos baixados pelo app serão salvos. Padrão: ~/Downloads.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                // Icone de pasta
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.accentColor)

                                // Caminho atual
                                if let folder = settings.downloadFolder {
                                    Text(folder.path)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundColor(.primary)
                                } else {
                                    Text("~/Downloads (padrão do sistema)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()
                            }

                            HStack(spacing: 8) {
                                Button(action: {
                                    settings.chooseDownloadFolder { newFolder in
                                        if newFolder != nil {
                                            downloadFolderChanged = true
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                downloadFolderChanged = false
                                            }
                                        }
                                    }
                                }) {
                                    Label("Escolher Pasta", systemImage: "folder.badge.plus")
                                }
                                .buttonStyle(.bordered)

                                if settings.downloadFolder != nil {
                                    Button(action: {
                                        settings.resetDownloadFolder()
                                    }) {
                                        Label("Restaurar Padrão", systemImage: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                if downloadFolderChanged {
                                    Text("Pasta salva!")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .transition(.opacity)
                                }
                            }

                            if let folder = settings.downloadFolder {
                                Button(action: { NSWorkspace.shared.open(folder) }) {
                                    Label("Abrir Pasta no Finder", systemImage: "arrow.up.right.square")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                            }
                        }
                        .padding(8)
                    }

                    // Atalho de teclado
                    GroupBox(label: Text("Atalho de Teclado").bold()) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Atalho atual:")
                                Spacer()
                                Button(action: { isListeningForHotKey = true }) {
                                    Text(isListeningForHotKey ? "Pressione as teclas..." : hotKeyString())
                                        .frame(minWidth: 160)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            isListeningForHotKey
                                                ? Color.red.opacity(0.15)
                                                : Color.secondary.opacity(0.1)
                                        )
                                        .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            if isListeningForHotKey {
                                Text("Pressione a combinação desejada. Clique fora para cancelar.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                    }

                    // Dimensoes em porcentagem
                    GroupBox(label: Text("Dimensões da Janela (% do monitor)").bold()) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading) {
                                Text("Largura: \(Int(localWidthPct * 100))% do monitor")
                                Slider(value: $localWidthPct, in: 0.01...1.0, step: 0.01)
                            }
                            VStack(alignment: .leading) {
                                Text("Altura: \(Int(localHeightPct * 100))% do monitor")
                                Slider(value: $localHeightPct, in: 0.01...1.0, step: 0.01)
                            }
                            VStack(alignment: .leading) {
                                Text("Margem do Topo: \(Int(localOffsetPct * 100))% do monitor")
                                Slider(value: $localOffsetPct, in: 0.0...0.50, step: 0.01)
                            }
                        }
                        .padding(8)
                    }

                    // Restaurar Padrões
                    GroupBox(label: Text("Restaurar Padrões").bold()) {
                        VStack(alignment: .leading, spacing: 12) {

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Restaura apenas largura (70%), altura (80%), margem (10%) e direção. As abas e o atalho de teclado não são alterados.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button(action: {
                                    settings.resetWindowDefaults()
                                    localWidthPct  = Double(settings.widthPercent)
                                    localHeightPct = Double(settings.heightPercent)
                                    localOffsetPct = Double(settings.verticalOffsetPercent)
                                    localDirection = settings.direction
                                    controller?.applySettings()
                                }) {
                                    Label("Restaurar Dimensões Padrão", systemImage: "arrow.counterclockwise")
                                }
                                .buttonStyle(.bordered)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Apaga TODAS as abas, configurações e dados salvos. O aplicativo volta ao estado de primeira execução.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button(action: {
                                    let alert = NSAlert()
                                    alert.messageText     = "Redefinir tudo?"
                                    alert.informativeText = "Todas as abas e configurações serão apagadas permanentemente. Esta ação não pode ser desfeita."
                                    alert.alertStyle      = .critical
                                    alert.addButton(withTitle: "Redefinir Tudo")
                                    alert.addButton(withTitle: "Cancelar")
                                    if alert.runModal() == .alertFirstButtonReturn {
                                        settings.fullReset()
                                        localWidthPct  = Double(settings.widthPercent)
                                        localHeightPct = Double(settings.heightPercent)
                                        localOffsetPct = Double(settings.verticalOffsetPercent)
                                        localDirection = settings.direction
                                        controller?.applySettings()
                                        presentationMode.wrappedValue.dismiss()
                                    }
                                }) {
                                    Label("Redefinir Tudo (Apagar Abas)", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                                .foregroundColor(.red)
                            }
                        }
                        .padding(8)
                    }

                    // Exportar / Importar
                    GroupBox(label: Text("Backup de Configurações").bold()) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Exporte suas abas e configurações para um arquivo JSON. Importe para restaurar em outro Mac.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                Button(action: exportSettings) {
                                    Label("Exportar", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)

                                Button(action: importSettings) {
                                    Label("Importar", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.bordered)

                                if showImportOK {
                                    Text("✅ Importado com sucesso")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .transition(.opacity)
                                }
                            }

                            if let err = exportError ?? importError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(8)
                    }

                    // Lista de abas
                    if !settings.tabs.isEmpty {
                        GroupBox(label: Text("Abas Cadastradas").bold()) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(settings.tabs) { tab in
                                    HStack {
                                        tab.getIcon()
                                            .resizable()
                                            .frame(width: 16, height: 16)
                                        Text(tab.title)
                                            .lineLimit(1)
                                        Spacer()
                                        if tab.isSuspended {
                                            Text("Suspensa")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(8)
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button("Cancelar") {
                    isListeningForHotKey = false
                    presentationMode.wrappedValue.dismiss()
                }
                Spacer()
                Button("Aplicar Alterações") {
                    applyAndClose()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isListeningForHotKey)
            }
            .padding()
        }
        .frame(width: 520, height: 640)
        .onAppear {
            localWidthPct  = Double(settings.widthPercent)
            localHeightPct = Double(settings.heightPercent)
            localOffsetPct = Double(settings.verticalOffsetPercent)
            localDirection = settings.direction
        }
        .background(
            KeyEventCapture(isListening: $isListeningForHotKey) { keyCode, modifiers in
                settings.hotKeyCode      = keyCode
                settings.hotKeyModifiers = modifiers
                isListeningForHotKey     = false
            }
        )
    }

    func applyAndClose() {
        settings.widthPercent          = CGFloat(localWidthPct)
        settings.heightPercent         = CGFloat(localHeightPct)
        settings.verticalOffsetPercent = CGFloat(localOffsetPct)
        settings.direction             = localDirection
        settings.saveSettings()
        controller?.applySettings()
        presentationMode.wrappedValue.dismiss()
    }

    func exportSettings() {
        exportError = nil
        guard let data = try? settings.exportJSON() else {
            exportError = "Erro ao gerar o arquivo de exportação."
            return
        }
        let panel = NSSavePanel()
        panel.title                  = "Exportar Configurações"
        panel.nameFieldStringValue   = "easybar_backup.json"
        panel.allowedContentTypes    = [.json]
        panel.canCreateDirectories   = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                exportError = "Erro ao salvar: \(error.localizedDescription)"
            }
        }
    }

    func importSettings() {
        importError = nil
        let panel = NSOpenPanel()
        panel.title             = "Importar Configurações"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles    = true
        panel.allowsMultipleSelection = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try settings.importJSON(data)
                withAnimation { showImportOK = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { showImportOK = false }
                }
                localWidthPct  = Double(settings.widthPercent)
                localHeightPct = Double(settings.heightPercent)
                localOffsetPct = Double(settings.verticalOffsetPercent)
                localDirection = settings.direction
                controller?.applySettings()
            } catch {
                importError = "Erro ao importar: \(error.localizedDescription)"
            }
        }
    }

    /// Monta a string legível do atalho atual usando HotKeyModifier centralizado.
    func hotKeyString() -> String {
        var str = ""
        if settings.hotKeyModifiers & HotKeyModifier.option.rawValue  != 0 { str += "⌥ " }
        if settings.hotKeyModifiers & HotKeyModifier.control.rawValue != 0 { str += "⌃ " }
        if settings.hotKeyModifiers & HotKeyModifier.shift.rawValue   != 0 { str += "⇧ " }
        if settings.hotKeyModifiers & HotKeyModifier.command.rawValue != 0 { str += "⌘ " }

        let keyMap: [Int: String] = [
            12:"Q", 0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X",
            8:"C", 9:"V", 11:"B", 13:"W", 14:"E", 15:"R", 17:"T", 16:"Y",
            31:"O", 32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M"
        ]
        str += keyMap[settings.hotKeyCode] ?? "Tecla \(settings.hotKeyCode)"
        return str
    }
}

// MARK: - Captura de Eventos de Teclado para Atalho

struct KeyEventCapture: NSViewRepresentable {
    @Binding var isListening: Bool
    var onCaptured: (Int, UInt32) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard self.isListening else { return event }

            // CORRIGIDO: a lógica anterior era defeituosa — a expressão
            // `modifiersOnly.contains(event.modifierFlags.intersection(modifiersOnly))`
            // é sempre verdadeira (qualquer interseção está contida em modifiersOnly),
            // tornando a condição equivalente a `keyCode != 0`, o que impedia a tecla
            // 'A' (keyCode == 0) de ser usada como atalho.
            //
            // Nova lógica: só aceita o evento se houver pelo menos um modificador
            // real pressionado, evitando que teclas soltas (como Enter ou Esc)
            // sejam registradas acidentalmente como atalho.
            let relevantMods: NSEvent.ModifierFlags = [.shift, .option, .control, .command]
            let pressedMods = event.modifierFlags.intersection(relevantMods)
            guard !pressedMods.isEmpty else { return event }

            let rawMods = UInt32(event.modifierFlags.rawValue)
            self.onCaptured(Int(event.keyCode), rawMods)
            return nil
        }
        context.coordinator.monitor = monitor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    class Coordinator {
        var monitor: Any?
    }
}

// MARK: - Bloco de Notas

struct NotesWindow: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var noteText:    String = ""
    @State private var showSaved:   Bool   = false
    @State private var showSavePanel = false

    private let storageKey = "quickNotes"

    var body: some View {
        VStack(spacing: 0) {
            // Barra de titulo (apenas label)
            HStack {
                Label("Bloco de Notas", systemImage: "note.text")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)

            Divider()

            // Area de texto
            TextEditor(text: $noteText)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .onChange(of: noteText) { _, newText in
                    UserDefaults.standard.set(newText, forKey: storageKey)
                }

            Divider()

            // Rodape com contador, botao salvar e fechar
            HStack {
                Text("\(noteText.count) caracteres · \(noteText.components(separatedBy: .newlines).count) linhas")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                if showSaved {
                    Text("Salvo!")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }

                Button(action: saveToFile) {
                    Label("Salvar .txt", systemImage: "arrow.down.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Salvar nota como arquivo .txt")

                Button("Fechar") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 500, height: 420)
        .onAppear {
            noteText = UserDefaults.standard.string(forKey: storageKey) ?? ""
        }
    }

    func saveToFile() {
        let panel = NSSavePanel()
        panel.title            = "Salvar Nota"
        panel.nameFieldStringValue = "nota.txt"
        panel.allowedContentTypes  = [.plainText]
        panel.canCreateDirectories = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)
        NSApp.activate(ignoringOtherApps: true)

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try noteText.write(to: url, atomically: true, encoding: .utf8)
                withAnimation {
                    showSaved = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showSaved = false }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText     = "Erro ao salvar"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
