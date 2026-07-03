import SwiftUI
import WebKit
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - User-Agent
// O Google bloqueia WKWebView com qualquer UA que contenha "Chrome/..." pois detecta
// que o motor real é AppleWebKit/605.x (Safari), não o Blink do Chrome.
// A solução correta é usar o UA do Safari nativo — aceito pelo Google, WhatsApp, Notion e Gemini.

private let kSafariUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
    "Version/17.6 Safari/605.1.15"

// MARK: - Utilitário de Endereço Local
// Função livre (não duplicada): usada por TabManager, WebViewCoordinator e SecondaryViews.
// Substitui as três implementações divergentes que existiam antes.

func isLocalNetworkAddress(_ host: String) -> Bool {
    if host.hasSuffix(".local") { return true }
    if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
    // RFC 1918: 172.16.0.0/12 (172.16–172.31)
    if host.hasPrefix("172.") {
        let parts = host.split(separator: ".")
        if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
    }
    let parts = host.split(separator: ".")
    if parts.count == 4 && parts.allSatisfy({ Int($0) != nil }) { return true }
    return false
}

// MARK: - DragAwareWebView
// Subclasse de WKWebView que aceita arquivos arrastados do Finder.
// O WKWebView não suporta drag-and-drop de arquivos nativamente no macOS —
// é necessário sobrescrever os métodos do NSDraggingDestination.

final class DragAwareWebView: WKWebView {

    private static let dragTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff, .fileContents,
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("NSFilenamesPboardType")
    ]

    /// URL a carregar no primeiro layout com frame não-nulo.
    ///
    /// No macOS 26 beta, chamar load() quando frame == .zero faz o WebContent
    /// process inicializar com tamanho 0×0 e o pipeline de renderização nunca
    /// recebe o tamanho correto. A solução é diferir load() para o primeiro
    /// layout() em que bounds.size > 0, garantindo que o frame já está definido.
    var pendingRequest: URLRequest?

    /// Disparado a cada passo de layout (incluindo o primeiro, após SwiftUI
    /// definir o frame via NSViewRepresentable). Chama load() uma única vez
    /// quando o frame se torna não-nulo.
    override func layout() {
        super.layout()
        guard let req = pendingRequest,
              bounds.size.width > 0,
              bounds.size.height > 0 else { return }
        pendingRequest = nil   // limpa ANTES de load() para evitar re-trigger
        load(req)
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        registerForDraggedTypes(Self.dragTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes(Self.dragTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles(in: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles(in: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let urls = fileURLs(from: pb), !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        // CORRIGIDO: sender.draggingLocation está em coordenadas da janela (NSWindow).
        // convert(_:from: nil) converte para coordenadas locais da view, que é o que
        // o JavaScript espera via elementFromPoint(x, y).
        let viewLocation = convert(sender.draggingLocation, from: nil)
        injectFilesViaDrop(urls: urls, at: viewLocation)
        return true
    }

    // MARK: Helpers

    private func hasFiles(in pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func fileURLs(from pb: NSPasteboard) -> [URL]? {
        pb.readObjects(forClasses: [NSURL.self],
                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    // MARK: Injeção de arquivos via JavaScript
    // Converte os arquivos para base64 e injeta como evento drop simulado.
    // Funciona em WhatsApp Web, Telegram Web, Gmail e outros sites com HTML5 drag-and-drop.

    private func injectFilesViaDrop(urls: [URL], at location: NSPoint) {
        // Fila serial evita race condition — múltiplas threads faziam .append concorrente.
        let serialQueue = DispatchQueue(label: "br.com.easybar.dragdrop")
        var fileDataArray: [(name: String, mime: String, base64: String)] = []
        let group = DispatchGroup()

        for url in urls {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let data = try? Data(contentsOf: url) else { return }
                let base64   = data.base64EncodedString()
                let mime     = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                             ?? "application/octet-stream"
                let safeName = url.lastPathComponent
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'",  with: "\\'")
                let item = (name: safeName, mime: mime, base64: base64)
                serialQueue.sync { fileDataArray.append(item) }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, !fileDataArray.isEmpty else { return }

            let filesJS = fileDataArray.map { f -> String in
                """
                (function() {
                    var b64 = '\(f.base64)';
                    var bin = atob(b64);
                    var arr = new Uint8Array(bin.length);
                    for (var i = 0; i < bin.length; i++) { arr[i] = bin.charCodeAt(i); }
                    return new File([arr], '\(f.name)', { type: '\(f.mime)' });
                })()
                """
            }.joined(separator: ",")

            let x = location.x
            // AppKit usa origem no canto inferior-esquerdo; CSS/JS usa superior-esquerdo.
            let y = self.bounds.height - location.y

            let js = """
            (function() {
                var files = [\(filesJS)];
                var dt = new DataTransfer();
                files.forEach(function(f) { dt.items.add(f); });
                var el = document.elementFromPoint(\(x), \(y)) || document.body;
                ['dragenter','dragover','drop'].forEach(function(type) {
                    var ev = new DragEvent(type, {
                        bubbles: true, cancelable: true,
                        clientX: \(x), clientY: \(y), dataTransfer: dt
                    });
                    el.dispatchEvent(ev);
                });
            })();
            """
            self.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - TabManager

/// Gerencia os `WKWebView` de cada aba, mantendo-os vivos em memória.
public final class TabManager: ObservableObject {

    @Published public var webViews:      [UUID: WKWebView] = [:]
    @Published public var loadingStates: [UUID: Bool]      = [:]

    /// Retenção forte dos Coordinators — evita delegates dangling.
    private var coordinators: [UUID: WebViewCoordinator] = [:]

    /// Referência ao `AppSettings` para acessar `effectiveDownloadFolder`.
    public var settings: AppSettings?

    /// IDs de abas cujo favicon já foi requisitado nesta sessão.
    public var faviconAttempted: Set<UUID> = []

    /// IDs de abas já exibidas ao menos uma vez (lazy loading).
    public var visitedTabs: Set<UUID> = []

    public init() {}

    // MARK: Acesso / Criação

    public func getWebView(for tab: WebTab) -> WKWebView {
        if let existing = webViews[tab.id] { return existing }

        let coordinator = WebViewCoordinator(tab: tab, tabManager: self)
        coordinators[tab.id] = coordinator

        let config  = makeConfiguration()
        let webView = DragAwareWebView(frame: .zero, configuration: config)
        webView.customUserAgent                     = kSafariUA
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification                 = true
        webView.navigationDelegate                  = coordinator
        webView.uiDelegate                          = coordinator

        webViews[tab.id] = webView
        // NÃO chamar load() aqui — o WKWebView tem frame:.zero nesse momento.
        // load() é disparado em DragAwareWebView.layout() quando o frame
        // se torna não-nulo pela primeira vez (após SwiftUI fazer o layout).
        webView.pendingRequest = buildRequest(for: tab.url)
        return webView
    }

    public func reloadOriginalURL(for tab: WebTab) {
        // Reload usa load() direto: o WKWebView já tem frame válido nesse ponto.
        getWebView(for: tab).load(buildRequest(for: tab.url))
    }

    public func suspendTab(_ tabId: UUID) {
        if let wv = webViews[tabId] {
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate         = nil
        }
        webViews.removeValue(forKey: tabId)
        coordinators.removeValue(forKey: tabId)
        loadingStates.removeValue(forKey: tabId)
    }

    // MARK: Configuração do WKWebView

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore                         = WKWebsiteDataStore.default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(
            WKUserScript(source: spoofScript(),
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        return config
    }

    private func spoofScript() -> String {
        """
        (function() {
            Object.defineProperty(navigator, 'webdriver', {
                get: function() { return false; },
                configurable: true
            });
        })();
        """
    }

    // MARK: URLRequest

    public func buildRequest(for url: URL) -> URLRequest {
        var urlString = url.absoluteString
        if !urlString.contains("://") {
            let host = urlString.split(separator: "/").first.map(String.init) ?? urlString
            urlString = (isLocalNetworkAddress(host) ? "http://" : "https://") + urlString
        }
        var request = URLRequest(url: URL(string: urlString) ?? url)
        request.timeoutInterval = 30
        return request
    }
}

// MARK: - WebViewWrapper

public struct WebViewWrapper: NSViewRepresentable {
    public typealias NSViewType = WKWebView

    let tab:        WebTab
    let tabManager: TabManager

    public func makeNSView(context: Context) -> WKWebView {
        tabManager.getWebView(for: tab)
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        // Garante que o WKWebView correto está configurado para carregar
        // quando o frame for definido. Se o nsView nunca carregou nada
        // (url==nil, não está carregando, e não tem pendingRequest),
        // configura pendingRequest para que layout() dispare o load().
        guard let dragView = nsView as? DragAwareWebView else { return }
        if dragView.url == nil && !dragView.isLoading && dragView.pendingRequest == nil {
            dragView.pendingRequest = tabManager.buildRequest(for: tab.url)
            dragView.needsLayout = true
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public final class Coordinator: NSObject {}
}

// MARK: - AuthPopupDelegate
// Gerencia o ciclo de vida de popups OAuth (ex: "Login com Google" no Notion).
// Quando o OAuth redireciona de volta ao domínio principal, fecha o painel
// e recarrega o WebView original para que a sessão autenticada seja aplicada.

private final class AuthPopupDelegate: NSObject, WKNavigationDelegate {
    let panel:       NSPanel
    let tabURL:      URL
    weak var mainWebView: WKWebView?

    init(panel: NSPanel, tabURL: URL, mainWebView: WKWebView) {
        self.panel       = panel
        self.tabURL      = tabURL
        self.mainWebView = mainWebView
    }

    private func baseDomain(_ host: String) -> String {
        let p = host.split(separator: ".")
        guard p.count >= 2 else { return host }
        return p.suffix(2).joined(separator: ".")
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url  = action.request.url,
              let host = url.host else { decisionHandler(.allow); return }

        let tabBase = baseDomain(tabURL.host ?? "")
        let urlBase = baseDomain(host)

        // Se o OAuth redirecionou de volta ao domínio principal, fecha o popup.
        if !tabBase.isEmpty && urlBase == tabBase {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.panel.close()
                self?.mainWebView?.reload()
            }
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url  = webView.url,
              let host = url.host else { return }
        let tabBase = baseDomain(tabURL.host ?? "")
        let urlBase = baseDomain(host)
        if !tabBase.isEmpty && urlBase == tabBase {
            DispatchQueue.main.async { [weak self] in
                self?.panel.close()
                self?.mainWebView?.reload()
            }
        }
    }
}

// MARK: - WebViewCoordinator

public final class WebViewCoordinator: NSObject,
                                       WKNavigationDelegate,
                                       WKUIDelegate,
                                       WKDownloadDelegate {

    let tab: WebTab
    weak var tabManager: TabManager?

    init(tab: WebTab, tabManager: TabManager) {
        self.tab        = tab
        self.tabManager = tabManager
    }

    // MARK: WKNavigationDelegate — Carregamento

    public func webView(_ webView: WKWebView,
                        didStartProvisionalNavigation navigation: WKNavigation!) {
        let tabId = tab.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tabManager?.loadingStates[tabId] = true
        }
    }

    public func webView(_ webView: WKWebView,
                        didFinish navigation: WKNavigation!) {
        let tabId = tab.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tabManager?.loadingStates[tabId] = false
            NotificationCenter.default.post(
                name: NSNotification.Name("WebPageLoaded"),
                object: webView,
                userInfo: ["tabId": tabId]
            )
            webView.window?.makeFirstResponder(webView)
        }
    }

    public func webView(_ webView: WKWebView,
                        didFail navigation: WKNavigation!,
                        withError error: Error) {
        let tabId = tab.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tabManager?.loadingStates[tabId] = false
        }
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        let tabId = tab.id
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tabManager?.loadingStates[tabId] = false
        }
        // Fallback HTTP para endereços locais com HTTPS com falha
        guard let url = webView.url ?? webView.backForwardList.currentItem?.url,
              url.scheme == "https",
              let host = url.host,
              isLocalNetworkAddress(host) else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        if let httpURL = components?.url {
            webView.load(URLRequest(url: httpURL))
        }
    }

    // MARK: WKNavigationDelegate — Política de Navegação

    // Domínios autorizados: nunca interceptados nem abertos externamente.
    // Visibilidade `internal` (não `private`) para que o erro de compilação
    // "inaccessible due to 'private' protection level" não ocorra caso outro
    // arquivo do módulo precise referenciar authDomains.
    internal static let authDomains: Set<String> = [

        // --- Autenticação OAuth ---
        "accounts.google.com", "google.com", "googleapis.com", "googleusercontent.com",
        "accounts.youtube.com", "login.microsoftonline.com", "login.live.com",
        "microsoftonline.com", "microsoft.com", "live.com",
        "appleid.apple.com", "auth0.com", "okta.com",
        "slack.com", "discord.com", "github.com",
        "anthropic.com", "openai.com", "proton.me",

        // --- Comunicação ---
        "web.whatsapp.com", "whatsapp.com", "web.telegram.org", "telegram.org",
        "app.slack.com", "mail.google.com", "outlook.live.com", "outlook.com",

        // --- Inteligência Artificial ---
        "chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai",
        "manus.ai", "phind.com", "huggingface.co", "you.com", "blackbox.ai",

        // --- Tradução e Escrita ---
        "deepl.com", "translate.google.com", "languagetool.org",

        // --- Produtividade e Tarefas ---
        "notion.so", "notionusercontent.com", "ticktick.com", "to-do.microsoft.com",
        "todoist.com", "keep.google.com", "trello.com", "calendar.google.com",
        "pomofocus.io", "linear.app",

        // --- Entretenimento e Áudio ---
        "open.spotify.com", "spotify.com", "music.youtube.com", "youtube.com",
        "play.pocketcasts.com", "pocketcasts.com", "lofi.co", "brain.fm",

        // --- Desenvolvimento ---
        "stackoverflow.com", "devdocs.io", "jsonhero.io", "explainshell.com",
        "vercel.com", "netlify.com", "gchq.github.io",

        // --- Utilitários de Arquivo ---
        "stirlingpdf.io", "excalidraw.com", "squoosh.app", "cloudconvert.com",
        "tinypng.com", "remove.bg", "convertio.co",

        // --- Pesquisa e Referência ---
        "scholar.google.com", "sci-hub.se", "libgen.is", "wikipedia.org", "wolframalpha.com",

        // --- Privacidade e Segurança ---
        "vault.bitwarden.com", "bitwarden.com", "temp-mail.org",
        "haveibeenpwned.com", "mail.proton.me",

        // --- Redes Sociais ---
        "instagram.com", "x.com", "twitter.com", "reddit.com",
        "app.buffer.com", "buffer.com",

        // --- Utilitários Rápidos ---
        "worldtimebuddy.com", "speedtest.net", "downdetector.com",
        "bundlephobia.com", "app.wallabag.it", "wallabag.it",
    ]

    internal func isAuthDomain(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return WebViewCoordinator.authDomains.contains(where: {
            host == $0 || host.hasSuffix("." + $0)
        })
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        if isAuthDomain(url) {
            decisionHandler(.allow)
            return
        }
        if isDifferentDomain(url, from: tab.url) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.showLinkDialog(url: url, webView: webView)
            }
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: WKNavigationDelegate — Política de Resposta (Download)

    /// Converte respostas não-renderizáveis e Content-Disposition:attachment em WKDownload.
    /// Sem isso, arquivos com cabeçalho de download (PDFs inline, binários, etc.) abrem
    /// como navegação normal e nunca chegam ao WKDownloadDelegate.
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Verifica Content-Disposition: attachment
        if let http = navigationResponse.response as? HTTPURLResponse {
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
            if disposition.lowercased().hasPrefix("attachment") {
                if #available(macOS 11.3, *) {
                    decisionHandler(.download)
                    return
                }
            }
        }
        // MIME type que o WKWebView não consegue renderizar (ex: .zip, .docx, binários)
        if !navigationResponse.canShowMIMEType {
            if #available(macOS 11.3, *) {
                decisionHandler(.download)
                return
            }
        }
        decisionHandler(.allow)
    }

    // MARK: WKNavigationDelegate — Download (macOS 11.3+)

    @available(macOS 11.3, *)
    public func webView(_ webView: WKWebView,
                        navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    @available(macOS 11.3, *)
    public func webView(_ webView: WKWebView,
                        navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKDownloadDelegate

    @available(macOS 11.3, *)
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        // Pasta padrão: pasta configurada pelo usuário ou ~/Downloads
        let defaultFolder = tabManager?.settings?.effectiveDownloadFolder
                         ?? FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Downloads")

        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL        = defaultFolder
            // Fica na frente do NSPanel flutuante do EasyBar
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.begin { result in
                completionHandler(result == .OK ? panel.url : nil)
            }
        }
    }

    @available(macOS 11.3, *)
    public func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText     = "Download Concluído"
            alert.informativeText = "O arquivo foi salvo com sucesso."
            alert.alertStyle      = .informational
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @available(macOS 11.3, *)
    public func download(_ download: WKDownload,
                         didFailWithError error: Error,
                         resumeData: Data?) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText     = "Erro no Download"
            alert.informativeText = error.localizedDescription
            alert.alertStyle      = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func showDownloadNotification(folder: URL) {
        let alert = NSAlert()
        alert.messageText     = "Download Concluído"
        alert.informativeText = "Arquivo salvo em:\n\(folder.path)"
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "Abrir Pasta")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: WKUIDelegate — Upload de Arquivos
    // CORRIGIDO: o NSOpenPanel ficava atrás do NSPanel flutuante.
    // Solução: nível popUpMenu + 1 (acima de qualquer floating panel) e makeKeyAndOrderFront
    // com delay de 50ms para que o painel principal libere o foco antes.

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles          = true
            panel.canChooseDirectories    = false
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.message                 = "Selecione o arquivo para enviar"
            panel.prompt                  = "Selecionar"
            panel.allowedContentTypes     = []
            // Nível acima de popUpMenu (101) garante ficar na frente do NSPanel floating (3)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }
    }

    // MARK: WKUIDelegate — window.open() / Popups OAuth
    // CORRIGIDO: antes, URLs de auth (ex: Google login no Notion) eram carregadas no
    // webView atual, substituindo a página e quebrando o fluxo OAuth.
    // Agora criamos um NSPanel temporário com um WKWebView que compartilha o mesmo
    // WKWebsiteDataStore (cookies/sessão). O AuthPopupDelegate fecha o painel quando
    // o OAuth redirecionar de volta ao domínio principal e recarrega a aba.

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }

        if isAuthDomain(url) {
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            popupWebView.customUserAgent = kSafariUA

            let authPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                styleMask:   [.titled, .closable, .resizable],
                backing:     .buffered,
                defer:       false
            )
            authPanel.title                = "Autenticação"
            authPanel.contentView          = popupWebView
            authPanel.level                = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)
            authPanel.isReleasedWhenClosed = false
            authPanel.center()

            let delegate = AuthPopupDelegate(panel: authPanel, tabURL: tab.url, mainWebView: webView)
            popupWebView.navigationDelegate = delegate
            // Retenção forte do delegate enquanto o painel existir
            objc_setAssociatedObject(authPanel, "authDelegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            authPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return popupWebView
        } else {
            NSWorkspace.shared.open(url)
            return nil
        }
    }

    /// Evita EXC_BAD_ACCESS quando o site chama `window.close()` em popup que não existe.
    public func webViewDidClose(_ webView: WKWebView) {}

    // MARK: Certificados SSL

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           isLocalNetworkAddress(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: Helpers

    private func isDifferentDomain(_ url: URL, from reference: URL) -> Bool {
        let a = baseDomain(url.host ?? "")
        let b = baseDomain(reference.host ?? "")
        return !a.isEmpty && !b.isEmpty && a != b
    }

    private func baseDomain(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    private func showLinkDialog(url: URL, webView: WKWebView) {
        let alert = NSAlert()
        alert.messageText     = "Abrir Link Externo"
        alert.informativeText = url.absoluteString
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "Abrir no Navegador")
        alert.addButton(withTitle: "Abrir nesta Aba")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  NSWorkspace.shared.open(url)
        case .alertSecondButtonReturn: webView.load(URLRequest(url: url))
        default: break
        }
    }
}
