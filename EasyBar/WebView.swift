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
//
// SEGURANÇA: só retorna `true` para hosts COMPROVADAMENTE na rede local —
// sufixo mDNS (`.local`, `localhost`) ou um literal de IP dentro de uma faixa
// privada/loopback/link-local. NUNCA casa por prefixo de string (o que deixava
// `10.evil.com` e `192.168.attacker.com` passarem) nem trata "qualquer coisa
// com 4 números" como local (o que desativava TLS para qualquer IP público).
// Onde isso é usado (bypass de certificado, downgrade para HTTP), um falso
// positivo é uma vulnerabilidade de MITM.

func isLocalNetworkAddress(_ host: String) -> Bool {
    let h = host.lowercased()

    // mDNS / Bonjour / loopback por nome
    if h == "localhost" || h.hasSuffix(".localhost") { return true }
    if h.hasSuffix(".local") { return true }

    // Literal IPv6 (URL.host já remove os colchetes)
    if h.contains(":") {
        if h == "::1" { return true }                              // loopback
        if h.hasPrefix("fe80:") { return true }                    // link-local fe80::/10
        if h.hasPrefix("fc") || h.hasPrefix("fd") { return true }  // ULA fc00::/7
        return false
    }

    // Literal IPv4 estrito: exatamente 4 octetos 0–255, sem zero à esquerda
    let octets = h.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    var v: [Int] = []
    for o in octets {
        guard !o.isEmpty, o.count <= 3,
              o.allSatisfy({ ("0"..."9").contains($0) }),
              !(o.count > 1 && o.first == "0"),
              let n = Int(o), (0...255).contains(n) else { return false }
        v.append(n)
    }
    switch (v[0], v[1]) {
    case (10, _):        return true   // 10.0.0.0/8
    case (127, _):       return true   // 127.0.0.0/8  loopback
    case (192, 168):     return true   // 192.168.0.0/16
    case (169, 254):     return true   // 169.254.0.0/16 link-local
    case (172, 16...31): return true   // 172.16.0.0/12
    default:             return false
    }
}

// MARK: - Domínio registrável (eTLD+1)
//
// `host.split(".").suffix(2)` tratava `bbc.co.uk` e `evil.co.uk` como o mesmo
// site — enfraquecendo o aviso de link externo e a checagem de origem do
// popup OAuth. Esta tabela é um subconjunto curado da Public Suffix List;
// cobre praticamente todo uso real sem precisar embarcar a PSL inteira.

private let kMultiLabelPublicSuffixes: Set<String> = [
    "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "net.uk", "sch.uk", "nhs.uk", "police.uk", "mod.uk",
    "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "blog.br",
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
    "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
    "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
    "co.za", "org.za",
    "com.mx", "org.mx", "gob.mx",
    "com.ar", "com.co", "com.pe", "com.ve", "com.uy",
    "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in",
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
    "com.tr", "com.sg", "com.hk", "com.tw", "com.ua", "com.my", "com.ph",
    "co.kr", "or.kr",
    "com.pl", "net.pl", "org.pl", "gov.pl",
    "com.ru", "net.ru", "org.ru",
    "com.es", "com.pt", "co.il", "com.sa",
]

/// Domínio registrável de um host: `a.b.example.co.uk` → `example.co.uk`,
/// `mail.google.com` → `google.com`. String vazia para hosts inválidos.
func registrableDomain(_ host: String) -> String {
    let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let parts = h.split(separator: ".").map(String.init)
    guard parts.count >= 2 else { return h }

    let lastTwo = parts.suffix(2).joined(separator: ".")
    if kMultiLabelPublicSuffixes.contains(lastTwo) {
        return parts.count >= 3 ? parts.suffix(3).joined(separator: ".") : lastTwo
    }
    return lastTwo
}

// MARK: - Validação de URL de aba
//
// SEGURANÇA: uma aba só pode carregar http/https. Sem isso, uma URL vinda de
// um backup JSON importado (ou digitada) com `file:///…`, `javascript:…` etc.
// seria carregada no WKWebView. `normalizedWebTabURL` valida na entrada;
// `TabManager.buildRequest` reforça na saída (dados antigos / importados).

let kAllowedTabSchemes: Set<String> = ["http", "https"]

/// Normaliza a entrada do usuário numa URL de aba válida (http/https com host), ou `nil`.
/// Tolerante a caracteres não-ASCII / não-codificados no caminho (URLs reais
/// digitadas), mas rígido no que importa para segurança: esquema e host.
func normalizedWebTabURL(from raw: String) -> URL? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if !s.contains("://") {
        var host = s.split(separator: "/").first.map(String.init) ?? s
        // remove :porta antes de classificar (host:3000 → host); não mexe em IPv6
        if let colon = host.lastIndex(of: ":"),
           !host[..<colon].contains(":"), !host[..<colon].isEmpty,
           host[host.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            host = String(host[..<colon])
        }
        s = (isLocalNetworkAddress(host) ? "http://" : "https://") + s
    }
    guard let url = URL(string: s, encodingInvalidCharacters: true),
          let scheme = url.scheme?.lowercased(), kAllowedTabSchemes.contains(scheme),
          let host = url.host, !host.isEmpty else { return nil }
    return url
}

// MARK: - DragAwareWebView
// Subclasse de WKWebView que garante o drop de arquivos do Finder.
//
// O WebKit atual JÁ entrega o drop de arquivos como um DragEvent nativo
// (com `dataTransfer.files` real) — o que funciona em WhatsApp, Gmail, etc.
// sem simulação. O problema histórico era `registerForDraggedTypes` SUBSTITUIR
// a lista de tipos do WebKit, quebrando o caminho nativo. Agora registramos a
// UNIÃO e deixamos o WebKit tentar primeiro; a injeção via JS é só a rede de
// segurança para sites cuja drop zone o WebKit ignora.

final class DragAwareWebView: WKWebView {

    private static let extraDragTypes: [NSPasteboard.PasteboardType] = [
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

    /// Acrescenta os tipos extras PRESERVANDO os que o WebKit já registrou —
    /// substituir a lista era o que quebrava o drop nativo.
    private func addExtraDragTypes() {
        registerForDraggedTypes(registeredDraggedTypes + Self.extraDragTypes)
    }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        addExtraDragTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addExtraDragTypes()
    }

    /// Operação que o WebKit sinalizou no último dragging{Entered,Updated}.
    /// Se vazia, o elemento sob o cursor não tem drop zone nativa → usamos o JS.
    private var lastNativeDragOperation: NSDragOperation = []

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastNativeDragOperation = super.draggingEntered(sender)
        if !lastNativeDragOperation.isEmpty { return lastNativeDragOperation }
        return hasFiles(in: sender.draggingPasteboard) ? .copy : lastNativeDragOperation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastNativeDragOperation = super.draggingUpdated(sender)
        if !lastNativeDragOperation.isEmpty { return lastNativeDragOperation }
        return hasFiles(in: sender.draggingPasteboard) ? .copy : lastNativeDragOperation
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // 1. Se o WebKit aceitou o drop no local do cursor (drop zone nativa da
        //    página), deixa ELE entregar — vira um DragEvent real com
        //    dataTransfer.files, que é o que WhatsApp/Gmail/Telegram esperam,
        //    sem simulação e sem o erro de MIME ("arquivo não compatível").
        if !lastNativeDragOperation.isEmpty, super.performDragOperation(sender) {
            return true
        }

        // 2. Fallback: WebKit não quis o drop ali (drop zone só em JS que ele
        //    ignora, ou nenhuma). Injeta o arquivo via JavaScript.
        guard let urls = fileURLs(from: sender.draggingPasteboard), !urls.isEmpty else {
            return false
        }
        // sender.draggingLocation está em coordenadas da janela; converte para a view.
        injectFilesViaDrop(urls: urls, at: convert(sender.draggingLocation, from: nil))
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

    /// Teto por arquivo. O conteúdo é carregado inteiro em memória + base64
    /// (+33%) + string JS — sem limite, arrastar um arquivo enorme derruba o app.
    private static let maxDragDropFileBytes = 60 * 1024 * 1024   // 60 MB
    private static let maxDragDropTotalBytes = 150 * 1024 * 1024

    private func injectFilesViaDrop(urls: [URL], at location: NSPoint) {
        // Fila serial evita race condition — múltiplas threads faziam .append concorrente.
        let serialQueue = DispatchQueue(label: "br.com.easybar.dragdrop")
        var files: [[String: String]] = []
        var totalBytes = 0
        var skipped = 0
        let group = DispatchGroup()

        for url in urls {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }

                // Checa tamanho ANTES de ler o arquivo para a memória.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= Self.maxDragDropFileBytes else {
                    serialQueue.sync { skipped += 1 }
                    return
                }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }

                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                         ?? "application/octet-stream"
                let entry: [String: String] = [
                    "name": url.lastPathComponent,
                    "mime": mime,
                    "b64":  data.base64EncodedString(),
                ]
                serialQueue.sync {
                    guard totalBytes + data.count <= Self.maxDragDropTotalBytes else {
                        skipped += 1
                        return
                    }
                    totalBytes += data.count
                    files.append(entry)
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            if skipped > 0 {
                let alert = NSAlert()
                alert.messageText = "Arquivo muito grande"
                alert.informativeText = "\(skipped) arquivo(s) acima de 60 MB não foram anexados por arrasto."
                alert.alertStyle = .warning
                alert.runModal()
            }
            guard !files.isEmpty else { return }

            // SEGURANÇA: o nome/mime do arquivo vão para o JS. Codificamos como
            // JSON (escapa aspas, barras invertidas, controle) em vez de escapar
            // à mão — o antigo `replacingOccurrences` de `'` e `\` deixava passar
            // quebras de linha e outros caracteres que quebravam/injetavam o script.
            guard let payloadData = try? JSONSerialization.data(withJSONObject: files),
                  var payloadJSON = String(data: payloadData, encoding: .utf8) else { return }
            // Endurece contra separadores de linha Unicode em engines antigas.
            payloadJSON = payloadJSON
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

            let x = Int(location.x)
            // AppKit usa origem no canto inferior-esquerdo; CSS/JS usa superior-esquerdo.
            let y = Int(self.bounds.height - location.y)
            let host = (self.url?.host ?? "").lowercased()
            let isWhatsApp = host.contains("whatsapp")

            // Estratégia:
            //  • WhatsApp: simula o drop na área da conversa (#main). Esse é o
            //    caminho nativo "soltar = enviar como documento" — não passa
            //    pela validação de `accept` do <input>, que rejeitava .md como
            //    "arquivo não compatível". Se o compositor não abrir, cai no
            //    <input type=file> com o MIME normalizado.
            //  • Demais sites: drop sintético no ponto onde o usuário soltou.
            //
            // Bug corrigido: no WebKit, `new DragEvent(type,{dataTransfer:dt})`
            // IGNORA o `dataTransfer` do construtor — `event.dataTransfer` vinha
            // `null` e o site não via arquivo nenhum. Agora sombreamos a
            // propriedade com `Object.defineProperty` no evento já criado.
            let js = """
            (function() {
                var payload = \(payloadJSON);
                var DROP_X = \(x), DROP_Y = \(y);

                function makeFiles(coerceText) {
                    return payload.map(function(f) {
                        var bin = atob(f.b64);
                        var arr = new Uint8Array(bin.length);
                        for (var i = 0; i < bin.length; i++) { arr[i] = bin.charCodeAt(i); }
                        var type = f.mime;
                        // Alguns destinos rejeitam MIMEs de texto "exóticos"
                        // (text/markdown, text/x-…) — normaliza para text/plain.
                        if (coerceText && /^text\\/(?!plain$|csv$|html$)/.test(type)) {
                            type = 'text/plain';
                        }
                        return new File([arr], f.name, { type: type });
                    });
                }
                function makeDT(files) {
                    var dt = new DataTransfer();
                    files.forEach(function(f) { dt.items.add(f); });
                    return dt;
                }

                function tryFileInput(files) {
                    var inputs = [].slice.call(document.querySelectorAll('input[type=file]'))
                        .filter(function(i) { return !i.disabled; });
                    if (!inputs.length) return false;
                    var mediaOnly = files.every(function(f) {
                        return /^image\\//.test(f.type) || /^video\\//.test(f.type);
                    });
                    var input = inputs.filter(function(i) {
                        var a = (i.getAttribute('accept') || '').toLowerCase();
                        if (mediaOnly) {
                            return !a || a === '*' || a === '*/*' || /image|video/.test(a);
                        }
                        return !a || a === '*' || a === '*/*' || !/image|video|audio/.test(a);
                    })[0] || inputs[inputs.length - 1];
                    try {
                        input.files = makeDT(files).files;
                        input.dispatchEvent(new Event('input',  { bubbles: true }));
                        input.dispatchEvent(new Event('change', { bubbles: true }));
                        return input.files && input.files.length > 0;
                    } catch (e) { return false; }
                }

                function fire(type, node, dt, cx, cy) {
                    var ev;
                    try {
                        ev = new DragEvent(type, {
                            bubbles: true, cancelable: true,
                            clientX: cx, clientY: cy, dataTransfer: dt
                        });
                    } catch (e) {
                        ev = new DragEvent(type, {
                            bubbles: true, cancelable: true, clientX: cx, clientY: cy
                        });
                    }
                    if (!ev.dataTransfer) {
                        try {
                            Object.defineProperty(ev, 'dataTransfer', {
                                configurable: true, get: function() { return dt; }
                            });
                        } catch (e) {}
                    }
                    node.dispatchEvent(ev);
                }
                function dropOn(node, files, cx, cy) {
                    var dt = makeDT(files);
                    fire('dragenter', node, dt, cx, cy);
                    fire('dragover',  node, dt, cx, cy);
                    setTimeout(function() {
                        var t = document.elementFromPoint(cx, cy) || node;
                        fire('drop', t, dt, cx, cy);
                    }, 90);
                }

                function whatsAppMain() { return document.querySelector('#main'); }
                function whatsAppChatOpen() {
                    var m = whatsAppMain();
                    return !!(m && m.querySelector('[contenteditable="true"]'));
                }

                // Este código só roda quando o drop NATIVO do WebKit falhou.
                if (\(isWhatsApp ? "true" : "false")) {
                    if (!whatsAppChatOpen()) { return "no-chat"; }
                    // input com MIME normalizado (evita "arquivo não compatível");
                    // drop sintético só se não houver input.
                    if (tryFileInput(makeFiles(true))) { return "wa-input"; }
                    var main = whatsAppMain();
                    var r = main.getBoundingClientRect();
                    dropOn(main, makeFiles(false),
                           Math.round(r.left + r.width / 2),
                           Math.round(r.top + r.height / 2));
                    return "wa-drop";
                }

                dropOn(document.elementFromPoint(DROP_X, DROP_Y) || document.body,
                       makeFiles(false), DROP_X, DROP_Y);
                return "drop";
            })();
            """
            self.evaluateJavaScript(js) { result, _ in
                guard (result as? String) == "no-chat" else { return }
                let alert = NSAlert()
                alert.messageText = "Abra uma conversa primeiro"
                alert.informativeText = "Para anexar um arquivo por arrasto no WhatsApp, abra a conversa de destino antes de soltar o arquivo."
                alert.alertStyle = .informational
                alert.runModal()
            }
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
        // Reforço: só http/https chega ao WKWebView. Uma aba com esquema
        // proibido (dado antigo ou backup importado) vira about:blank.
        let target = normalizedWebTabURL(from: url.absoluteString)
                  ?? URL(string: "about:blank")!
        var request = URLRequest(url: target)
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

    private func baseDomain(_ host: String) -> String { registrableDomain(host) }

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

    /// URLs de navegações link-activated para outro domínio, aguardando a
    /// resposta HTTP para decidir entre "abrir link externo" e "baixar arquivo".
    /// Sem isso, links de download hospedados em CDNs (files.slack.com,
    /// *.googleusercontent.com, S3, etc.) eram cancelados e viravam o diálogo
    /// "Abrir Link Externo" em vez de baixar.
    private var pendingCrossDomainNavigations: Set<URL> = []

    /// WebViews de popup criados para conter downloads iniciados via window.open()
    /// ou target="_blank". Retidos até o download começar ou o popup fechar,
    /// senão o ARC os desalocaria antes do WKDownload nascer.
    private var transientPopups: [WKWebView] = []

    /// Hosts de rede local para os quais já tentamos o fallback HTTPS→HTTP.
    /// Evita loop de downgrade e uma segunda tentativa em texto claro.
    private var httpDowngradedHosts: Set<String> = []

    /// Chave para `objc_setAssociatedObject` (endereço estável e único).
    private static var authDelegateKey: UInt8 = 0

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
        let nsError = error as NSError

        // Navegação abortou antes da resposta: descarta o pedido pendente
        // de decisão cross-domain para não acumular URLs órfãs.
        if let failedURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            pendingCrossDomainNavigations.remove(failedURL)
        }

        // Fallback HTTP — SOMENTE para dispositivos da rede local sem TLS.
        //
        // SEGURANÇA: nunca faz downgrade para host público (isLocalNetworkAddress
        // só reconhece IP privado / .local), só reage a erros de conexão segura,
        // usa a URL que REALMENTE falhou (não webView.url, que é a página
        // anterior) e tenta no máximo uma vez por host (sem retry em texto claro).
        let downgradeWorthy: Set<Int> = [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorCannotConnectToHost,
        ]
        guard nsError.domain == NSURLErrorDomain,
              downgradeWorthy.contains(nsError.code),
              let failed = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url,
              failed.scheme == "https",
              let host = failed.host,
              isLocalNetworkAddress(host),
              !httpDowngradedHosts.contains(host) else { return }

        httpDowngradedHosts.insert(host)
        var components = URLComponents(url: failed, resolvingAgainstBaseURL: false)
        components?.scheme = "http"
        if let httpURL = components?.url {
            NSLog("[EasyBar] HTTPS falhou para host local %@ — tentando HTTP uma vez", host)
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
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // 1. Download explícito: <a download>, blob:/data: com download,
        //    "Salvar link como" do menu de contexto. O WebKit liga
        //    shouldPerformDownload — é assim que a maioria dos apps (Gemini,
        //    ChatGPT, Google Docs) exporta arquivos. Precisa vir ANTES do
        //    guard de navigationType, pois o clique sintético via JS tem
        //    navigationType .other, não .linkActivated.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow, preferences)
            return
        }
        if isAuthDomain(url) {
            decisionHandler(.allow, preferences)
            return
        }
        if isDifferentDomain(url, from: tab.url) {
            // Pode ser uma página externa OU um download hospedado em CDN.
            // Deixa a navegação começar e decide em decidePolicyFor:navigationResponse,
            // quando Content-Disposition / MIME já são conhecidos.
            if navigationAction.targetFrame?.isMainFrame ?? true {
                pendingCrossDomainNavigations.insert(url)
            }
            decisionHandler(.allow, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    // MARK: WKNavigationDelegate — Política de Resposta (Download)

    /// Converte respostas não-renderizáveis e Content-Disposition:attachment em WKDownload.
    /// Sem isso, arquivos com cabeçalho de download (PDFs inline, binários, etc.) abrem
    /// como navegação normal e nunca chegam ao WKDownloadDelegate.
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let responseURL = navigationResponse.response.url

        // Content-Disposition: attachment  →  download
        var isAttachment = false
        if let http = navigationResponse.response as? HTTPURLResponse {
            let disposition = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            isAttachment = disposition.contains("attachment")
        }

        if isAttachment || !navigationResponse.canShowMIMEType {
            if let responseURL { pendingCrossDomainNavigations.remove(responseURL) }
            decisionHandler(.download)
            return
        }

        // Página renderizável em outro domínio, aberta por clique do usuário:
        // aí sim perguntamos se abre no navegador padrão ou nesta aba.
        if let responseURL,
           navigationResponse.isForMainFrame,
           pendingCrossDomainNavigations.remove(responseURL) != nil {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.showLinkDialog(url: responseURL, webView: webView)
            }
            return
        }

        decisionHandler(.allow)
    }

    // MARK: WKNavigationDelegate — Download (macOS 11.3+)

    @available(macOS 11.3, *)
    public func webView(_ webView: WKWebView,
                        navigationResponse: WKNavigationResponse,
                        didBecome download: WKDownload) {
        download.delegate = self
        releaseTransientPopup(webView)
    }

    @available(macOS 11.3, *)
    public func webView(_ webView: WKWebView,
                        navigationAction: WKNavigationAction,
                        didBecome download: WKDownload) {
        download.delegate = self
        releaseTransientPopup(webView)
    }

    // MARK: WKDownloadDelegate

    @available(macOS 11.3, *)
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let manager = DownloadsManager.shared
        let folder  = tabManager?.settings?.effectiveDownloadFolder
                   ?? AppSettings.defaultDownloadFolder
        let ask     = tabManager?.settings?.askDownloadLocation ?? true

        // Nome vindo do servidor (Content-Disposition) — nunca usar cru.
        let safeName = DownloadsManager.sanitizedFilename(suggestedFilename)

        DispatchQueue.main.async {
            manager.register(download, suggestedFilename: safeName)
            AppDelegate.shared?.showDownloadsWindow(activate: false)

            // Entrega o arquivo no destino escolhido.
            let deliver: (URL?) -> Void = { url in
                if let url {
                    // WKDownload falha se o arquivo já existir. Só removemos um
                    // arquivo REGULAR pré-existente (nunca diretório/symlink) e
                    // apenas quando o usuário escolheu o caminho explicitamente
                    // pelo NSSavePanel; no caminho automático usamos um nome
                    // único, então nada é apagado.
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                       !isDir.boolValue {
                        try? FileManager.default.removeItem(at: url)
                    }
                    manager.setDestination(url, for: download)
                }
                completionHandler(url)
            }

            guard ask else {
                deliver(DownloadsManager.uniqueDestination(in: folder, filename: safeName))
                return
            }

            let panel = NSSavePanel()
            panel.nameFieldStringValue = safeName
            panel.directoryURL         = folder
            panel.canCreateDirectories = true

            Self.present(panel,
                         host: download.webView?.window,
                         openDownloadsAsHost: true) { result in
                deliver(result == .OK ? panel.url : nil)
            }
        }
    }

    // MARK: Apresentação de NSSavePanel / NSOpenPanel
    //
    // O painel do EasyBar é `.floating` + `.nonactivatingPanel`: um
    // NSSavePanel/NSOpenPanel apresentado sobre ele — como janela livre
    // (`begin`) ou até como sheet — fica coberto e os cliques do mouse
    // continuam indo para o painel. Só o campo de texto em foco responde
    // (ao teclado) → a janela parece "travada".
    //
    // Solução em duas partes:
    //   1. baixar o nível do painel do EasyBar para `.normal` enquanto o
    //      painel do sistema estiver na tela (restaurado no fim);
    //   2. apresentar como SHEET preso a uma janela real — a de Downloads,
    //      que é uma NSWindow comum e previsível. `begin` livre só como
    //      último recurso.

    static func present(_ panel: NSSavePanel,
                        host preferredHost: NSWindow?,
                        openDownloadsAsHost: Bool,
                        completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let slide = AppDelegate.shared?.windowController
        NSApp.activate(ignoringOtherApps: true)
        slide?.suppressFloatingLevel()

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            slide?.restoreFloatingLevel()
            completion(response)
        }

        if openDownloadsAsHost {
            AppDelegate.shared?.showDownloadsWindow(activate: true)
        }

        // Ordem de preferência de host da sheet:
        //  1. janela de Downloads (NSWindow comum, previsível) — para downloads;
        //  2. host indicado (o painel do EasyBar) se estiver de fato na tela;
        //  3. begin() livre — último recurso.
        if openDownloadsAsHost, let host = AppDelegate.shared?.downloadsWindow {
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else if slide?.isVisible == true,
                  let host = preferredHost ?? slide?.window,
                  host.isVisible {
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else if let host = AppDelegate.shared?.downloadsWindow {
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    @available(macOS 11.3, *)
    public func downloadDidFinish(_ download: WKDownload) {
        DispatchQueue.main.async {
            DownloadsManager.shared.markFinished(download)
            AppDelegate.shared?.showDownloadsWindow(activate: false)
        }
    }

    @available(macOS 11.3, *)
    public func download(_ download: WKDownload,
                         didFailWithError error: Error,
                         resumeData: Data?) {
        DispatchQueue.main.async {
            DownloadsManager.shared.markFailed(download, error: error)
        }
    }

    // MARK: WKUIDelegate — Upload de Arquivos
    // O NSOpenPanel sofre do mesmo problema do NSSavePanel de download: coberto
    // pelo painel flutuante `.nonactivatingPanel`, os cliques não chegam nele.
    // Reusa Self.present (baixa o nível do painel + apresenta como sheet).

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        DispatchQueue.main.async { [weak webView] in
            let panel = NSOpenPanel()
            panel.canChooseFiles          = true
            panel.canChooseDirectories    = false
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.message                 = "Selecione o arquivo para enviar"
            panel.prompt                  = "Selecionar"
            panel.allowedContentTypes     = []

            Self.present(panel,
                         host: webView?.window,
                         openDownloadsAsHost: false) { response in
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
        let url = navigationAction.request.url

        // Popup que é (ou vai virar) um download: window.open() seguido de
        // <a download> / blob:, ou target="_blank" apontando para um arquivo.
        // Mantém dentro do app num WebView efêmero — senão o download ia para
        // o Safari (NSWorkspace.open) ou se perdia (about:blank).
        // Restrito a esquemas "web" — um popup file://, smb://, etc. NÃO deve
        // virar um WebView nosso; cai no openExternalURL (que recusa).
        let scheme = url?.scheme?.lowercased()
        let webishScheme = scheme == nil || ["http", "https", "blob", "data", "about"].contains(scheme!)
        let looksLikeDownload =
            navigationAction.shouldPerformDownload ||
            (webishScheme && (url == nil || url?.host == nil || scheme == "blob" || scheme == "data"))

        let isAuth = url.map { self.isAuthDomain($0) } ?? false
        if looksLikeDownload && !isAuth {
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent   = kSafariUA
            popup.navigationDelegate = self
            popup.uiDelegate         = self
            retainTransientPopup(popup)
            return popup
        }

        guard let url else { return nil }

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
            // Retenção forte do delegate enquanto o painel existir.
            // Chave estável (ponteiro único) em vez de string literal.
            objc_setAssociatedObject(authPanel, &Self.authDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

            authPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return popupWebView
        } else {
            // window.open() para domínio comum → abre no navegador padrão,
            // mas só se for um esquema de navegação (http/https/mailto).
            Self.openExternalURL(url)
            return nil
        }
    }

    /// Evita EXC_BAD_ACCESS quando o site chama `window.close()` em popup que não existe.
    public func webViewDidClose(_ webView: WKWebView) {
        releaseTransientPopup(webView)
    }

    // MARK: Popups efêmeros (contêineres de download)

    private func retainTransientPopup(_ webView: WKWebView) {
        transientPopups.append(webView)
        // Rede de segurança: se nenhum download nascer (ex.: popup de anúncio),
        // libera após 20s para não vazar o WebContent process.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak webView] in
            guard let webView else { return }
            self?.releaseTransientPopup(webView)
        }
    }

    private func releaseTransientPopup(_ webView: WKWebView) {
        guard let idx = transientPopups.firstIndex(where: { $0 === webView }) else { return }
        transientPopups[idx].navigationDelegate = nil
        transientPopups[idx].uiDelegate         = nil
        transientPopups.remove(at: idx)
    }

    // MARK: Certificados SSL
    //
    // SEGURANÇA: aceitamos certificado não confiável APENAS para hosts na rede
    // local (roteador, NAS, impressora com certificado autoassinado) — validado
    // por `isLocalNetworkAddress`, que só reconhece literais de IP privado e
    // nomes `.local`/`localhost`. Para qualquer outro host, `performDefaultHandling`
    // aplica a validação normal de cadeia de certificados. Um bug em
    // `isLocalNetworkAddress` que deixe passar um host público reintroduz MITM.

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
        let a = registrableDomain(url.host ?? "")
        let b = registrableDomain(reference.host ?? "")
        return !a.isEmpty && !b.isEmpty && a != b
    }

    // MARK: Abertura de URL externa (fora do WKWebView)
    //
    // SEGURANÇA: conteúdo web só pode nos pedir para abrir esquemas de navegação.
    // Sem esta checagem, um `window.open("smb://…")` / `vnc://` / `ftp://` /
    // `x-apple-*` de qualquer página aciona o handler de esquema do macOS
    // (montar share de rede, prompt de credencial, abrir app de terceiro).

    private static let externallyOpenableSchemes: Set<String> = ["http", "https", "mailto"]

    @discardableResult
    static func openExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              externallyOpenableSchemes.contains(scheme) else {
            NSLog("[EasyBar] Recusado abrir URL de esquema não permitido: %@", url.scheme ?? "nil")
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    private func showLinkDialog(url: URL, webView: WKWebView) {
        // Só oferece "abrir" para URLs http/https/mailto — ver openExternalURL.
        guard let scheme = url.scheme?.lowercased(),
              WebViewCoordinator.externallyOpenableSchemes.contains(scheme) else {
            return
        }

        let alert = NSAlert()
        alert.messageText     = "Abrir Link Externo"
        alert.informativeText = String(url.absoluteString.prefix(300))
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "Abrir no Navegador")
        if scheme == "http" || scheme == "https" {
            alert.addButton(withTitle: "Abrir nesta Aba")
        }
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            WebViewCoordinator.openExternalURL(url)
        case .alertSecondButtonReturn where scheme == "http" || scheme == "https":
            webView.load(URLRequest(url: url))
        default:
            break
        }
    }
}
