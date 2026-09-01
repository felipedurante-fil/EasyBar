import Foundation
import AppKit
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Versão do Aplicativo
/// Fonte única de verdade para a versão. Usada em SettingsSnapshot e no About.
public let kAppVersion = "1.6.1"

// MARK: - Direção do Deslizamento

public enum WindowDirection: String, Codable, CaseIterable {
    case rightToLeft = "Direita para Esquerda"
    case leftToRight = "Esquerda para Direita"
    case topToBottom = "De Cima para Baixo"
    case bottomToTop = "De Baixo para Cima"
}

// MARK: - Modificadores do Atalho de Teclado
// Centralizado aqui para evitar magic numbers duplicados em SlideWindowController,
// SecondaryViews e Models.
public enum HotKeyModifier: UInt32 {
    case option  = 2048
    case control = 4096
    case shift   = 131072
    case command = 256
}

// MARK: - Modelo de Aba

public struct WebTab: Identifiable, Codable, Equatable {
    public var id:          UUID   = UUID()
    public var title:       String
    public var url:         URL
    public var faviconData: Data?
    public var isSuspended: Bool   = false

    public init(
        id:          UUID   = UUID(),
        title:       String,
        url:         URL,
        faviconData: Data?  = nil,
        isSuspended: Bool   = false
    ) {
        self.id          = id
        self.title       = title
        self.url         = url
        self.faviconData = faviconData
        self.isSuspended = isSuspended
    }

    /// Retorna o ícone do site como `NSImage`. Se não houver favicon, retorna o ícone de globo.
    public func nsImage() -> NSImage {
        if let data = faviconData, let img = NSImage(data: data) { return img }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
    }

    /// Retorna o ícone do site como `Image` do SwiftUI.
    /// CORRIGIDO: método que faltava — ContentView e SecondaryViews chamavam getIcon()
    /// mas WebTab só tinha nsImage(). Causa de crash de compilação.
    public func getIcon() -> Image {
        Image(nsImage: nsImage())
    }
}

// MARK: - Snapshot Exportável

public struct SettingsSnapshot: Codable {
    public var tabs:                  [WebTab]
    public var widthPercent:          Double
    public var heightPercent:         Double
    public var verticalOffsetPercent: Double
    public var direction:             WindowDirection
    public var hotKeyCode:            Int
    public var hotKeyModifiers:       UInt32
    public var launchAtLogin:         Bool
    public var appVersion:            String = kAppVersion
}

// MARK: - Configurações do Aplicativo

public final class AppSettings: ObservableObject {

    // MARK: Chaves de UserDefaults
    private enum Keys {
        static let tabs                   = "savedTabs"
        static let selectedTabId          = "selectedTabId"
        static let widthPercent           = "widthPercent"
        static let heightPercent          = "heightPercent"
        static let verticalOffsetPercent  = "verticalOffsetPercent"
        static let direction              = "windowDirection"
        static let launchAtLogin          = "launchAtLogin"
        static let hotKeyCode             = "hotKeyCode"
        static let hotKeyModifiers        = "hotKeyModifiers"
        static let downloadFolderBookmark = "downloadFolderBookmark"
        static let askDownloadLocation    = "askDownloadLocation"
        // Chaves legadas — lidas uma vez para migração, depois removidas
        static let windowWidth            = "windowWidth"
        static let windowHeight           = "windowHeight"
        static let verticalOffset         = "verticalOffset"
        static let alwaysMainMonitor      = "alwaysMainMonitor"
    }

    // MARK: Valores Padrão
    private enum Defaults {
        static let widthPercent:          CGFloat         = 0.70
        static let heightPercent:         CGFloat         = 0.80
        static let verticalOffsetPercent: CGFloat         = 0.10
        static let direction:             WindowDirection = .rightToLeft
        static let hotKeyCode:            Int             = 12      // Q
        static let hotKeyModifiers:       UInt32          = HotKeyModifier.option.rawValue
    }

    @Published public var tabs:                  [WebTab]        = []
    @Published public var selectedTabId:         UUID?
    /// Porcentagem da largura do monitor principal (0.01–1.0). Padrão: 70%.
    @Published public var widthPercent:          CGFloat         = Defaults.widthPercent
    /// Porcentagem da altura do monitor principal (0.01–1.0). Padrão: 80%.
    @Published public var heightPercent:         CGFloat         = Defaults.heightPercent
    /// Offset vertical a partir do topo (0.0–0.5). Padrão: 10%.
    @Published public var verticalOffsetPercent: CGFloat         = Defaults.verticalOffsetPercent
    @Published public var direction:             WindowDirection = Defaults.direction
    @Published public var hotKeyCode:            Int             = Defaults.hotKeyCode
    @Published public var hotKeyModifiers:       UInt32          = Defaults.hotKeyModifiers
    /// Pasta de destino para downloads. `nil` = usar `~/Downloads` (padrão do sistema).
    @Published public var downloadFolder:        URL?            = nil
    /// Quando `true`, cada download abre um `NSSavePanel` perguntando onde salvar.
    /// Quando `false`, o arquivo vai direto para `effectiveDownloadFolder`.
    @Published public var askDownloadLocation:   Bool            = true

    @Published public var launchAtLogin: Bool = false {
        didSet {
            guard oldValue != launchAtLogin else { return }
            applyLaunchAtLogin(launchAtLogin)
            // CORRIGIDO: saveSettings() removido daqui — o auto-save com debounce
            // de 500ms em setupAutoSave() já persiste a alteração. Chamá-lo aqui
            // causava double-save toda vez que o toggle era acionado.
        }
    }

    private var cancellables = Set<AnyCancellable>()

    public init() {
        loadSettings()
        setupAutoSave()
    }

    // MARK: - Auto-save com Debounce

    private func setupAutoSave() {
        objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.saveSettings() }
            .store(in: &cancellables)
    }

    // MARK: - Pasta de Downloads

    /// Pasta `~/Downloads` **real** do usuário.
    ///
    /// IMPORTANTE: em app sandboxed, `FileManager.homeDirectoryForCurrentUser`
    /// aponta para `~/Library/Containers/<bundle-id>/Data` — uma pasta oculta.
    /// `url(for: .downloadsDirectory)` resolve para o `~/Downloads` verdadeiro
    /// graças à entitlement `com.apple.security.files.downloads.read-write`.
    public static var systemDownloadsFolder: URL {
        if let url = try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) {
            return url
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
    }

    /// Pasta padrão do EasyBar quando o usuário não escolheu uma: `~/Downloads/EasyBar`.
    /// Mantém os arquivos baixados pelo app separados do resto de `~/Downloads`.
    public static var defaultDownloadFolder: URL {
        let folder = systemDownloadsFolder.appendingPathComponent("EasyBar", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Retorna a pasta efetiva de downloads:
    /// - Pasta personalizada configurada (se existir no disco) → usa ela.
    /// - Caso contrário → `~/Downloads/EasyBar` (criando se necessário).
    public var effectiveDownloadFolder: URL {
        if let custom = downloadFolder {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: custom.path, isDirectory: &isDir),
               isDir.boolValue {
                return custom
            }
        }
        return AppSettings.defaultDownloadFolder
    }

    /// Remove a pasta de downloads personalizada e o bookmark salvo.
    public func resetDownloadFolder() {
        downloadFolder = nil
        UserDefaults.standard.removeObject(forKey: Keys.downloadFolderBookmark)
    }

    /// Apresenta um `NSOpenPanel` para o usuário escolher a pasta de downloads.
    /// Persiste a escolha como security-scoped bookmark para acesso entre reinicializações.
    public func chooseDownloadFolder(completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.title                   = "Escolher Pasta de Downloads"
            panel.message                 = "Selecione onde os arquivos baixados serão salvos"
            panel.prompt                  = "Escolher"
            panel.canChooseFiles          = false
            panel.canChooseDirectories    = true
            panel.canCreateDirectories    = true
            panel.allowsMultipleSelection = false
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue)
            NSApp.activate(ignoringOtherApps: true)
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else {
                    completion(nil)
                    return
                }
                if let bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(bookmark, forKey: Keys.downloadFolderBookmark)
                }
                self?.downloadFolder = url
                completion(url)
            }
        }
    }

    /// Restaura a pasta de downloads a partir do security-scoped bookmark salvo.
    private func restoreDownloadFolder() {
        guard let bookmarkData = UserDefaults.standard.data(
            forKey: Keys.downloadFolderBookmark) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
        _ = url.startAccessingSecurityScopedResource()
        downloadFolder = url
        // Renova o bookmark se ficou obsoleto (pasta movida/renomeada)
        if isStale,
           let fresh = try? url.bookmarkData(
               options: .withSecurityScope,
               includingResourceValuesForKeys: nil,
               relativeTo: nil
           ) {
            UserDefaults.standard.set(fresh, forKey: Keys.downloadFolderBookmark)
        }
    }

    // MARK: - Restaurar Padrões

    /// Restaura apenas as dimensões e direção da janela.
    /// As abas e o atalho de teclado **não** são alterados.
    public func resetWindowDefaults() {
        widthPercent          = Defaults.widthPercent
        heightPercent         = Defaults.heightPercent
        verticalOffsetPercent = Defaults.verticalOffsetPercent
        direction             = Defaults.direction
        saveSettings()
    }

    /// Reset total: apaga todas as abas, limpa o `UserDefaults` e restaura
    /// o app ao estado de primeira execução.
    public func fullReset() {
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        } else {
            let ud = UserDefaults.standard
            [Keys.tabs, Keys.selectedTabId, Keys.widthPercent, Keys.heightPercent,
             Keys.verticalOffsetPercent, Keys.direction, Keys.hotKeyCode,
             Keys.hotKeyModifiers, Keys.launchAtLogin, Keys.downloadFolderBookmark]
                .forEach { ud.removeObject(forKey: $0) }
        }
        tabs                  = []
        selectedTabId         = nil
        widthPercent          = Defaults.widthPercent
        heightPercent         = Defaults.heightPercent
        verticalOffsetPercent = Defaults.verticalOffsetPercent
        direction             = Defaults.direction
        hotKeyCode            = Defaults.hotKeyCode
        hotKeyModifiers       = Defaults.hotKeyModifiers
        downloadFolder        = nil
        askDownloadLocation   = true
    }

    // MARK: - Launch at Login

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    if service.status == .enabled { try service.unregister() }
                }
            } catch {
                print("[LaunchAtLogin] Erro: \(error.localizedDescription)")
            }
        } else {
            let bundleId = Bundle.main.bundleIdentifier ?? ""
            SMLoginItemSetEnabled(bundleId as CFString, enabled)
        }
    }

    private func readLaunchAtLoginState() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
    }

    // MARK: - Persistência

    public func saveSettings() {
        let ud = UserDefaults.standard
        if let encoded = try? JSONEncoder().encode(tabs) {
            ud.set(encoded, forKey: Keys.tabs)
        }
        ud.set(selectedTabId?.uuidString,     forKey: Keys.selectedTabId)
        ud.set(Double(widthPercent),          forKey: Keys.widthPercent)
        ud.set(Double(heightPercent),         forKey: Keys.heightPercent)
        ud.set(Double(verticalOffsetPercent), forKey: Keys.verticalOffsetPercent)
        ud.set(direction.rawValue,            forKey: Keys.direction)
        ud.set(launchAtLogin,                 forKey: Keys.launchAtLogin)
        ud.set(hotKeyCode,                    forKey: Keys.hotKeyCode)
        ud.set(Int(hotKeyModifiers),          forKey: Keys.hotKeyModifiers)
        ud.set(askDownloadLocation,           forKey: Keys.askDownloadLocation)
        // downloadFolder é persistido via security-scoped bookmark em chooseDownloadFolder()
    }

    public func loadSettings() {
        let ud = UserDefaults.standard

        // Abas
        if let data    = ud.data(forKey: Keys.tabs),
           let decoded = try? JSONDecoder().decode([WebTab].self, from: data) {
            tabs = decoded
        }

        // Aba selecionada
        if let idStr = ud.string(forKey: Keys.selectedTabId),
           let uuid  = UUID(uuidString: idStr) {
            selectedTabId = uuid
        }

        // Dimensões — com migração automática de pixels legados para porcentagem.
        // CORRIGIDO: heightPercent e verticalOffsetPercent agora passam usesHeight: true
        // para que o divisor da migração legada use screen.frame.height em vez de .width.
        // Antes, ambos eram divididos por .width, gerando percentuais ~56% menores em
        // monitores 16:9 (1920×1080).
        widthPercent          = migratePercent(
            key: Keys.widthPercent, legacyKey: Keys.windowWidth,
            defaultValue: Defaults.widthPercent,
            legacyMigrationValue: 0.75,
            clamp: 0.01...1.0,
            usesHeight: false
        )
        heightPercent         = migratePercent(
            key: Keys.heightPercent, legacyKey: Keys.windowHeight,
            defaultValue: Defaults.heightPercent,
            legacyMigrationValue: 0.65,
            clamp: 0.01...1.0,
            usesHeight: true
        )
        verticalOffsetPercent = migratePercent(
            key: Keys.verticalOffsetPercent, legacyKey: Keys.verticalOffset,
            defaultValue: Defaults.verticalOffsetPercent,
            legacyMigrationValue: 0.03,
            clamp: 0.0...0.5,
            usesHeight: true
        )

        // Direção
        if let dirStr = ud.string(forKey: Keys.direction),
           let d      = WindowDirection(rawValue: dirStr) {
            direction = d
        }

        // Launch at Login — lido do sistema, não do UserDefaults
        _launchAtLogin = Published(initialValue: readLaunchAtLoginState())

        // Atalho de teclado
        let savedCode = ud.integer(forKey: Keys.hotKeyCode)
        hotKeyCode    = savedCode > 0 ? savedCode : Defaults.hotKeyCode

        let savedMods   = ud.integer(forKey: Keys.hotKeyModifiers)
        hotKeyModifiers = savedMods > 0 ? UInt32(savedMods) : Defaults.hotKeyModifiers

        // Perguntar onde salvar cada download (padrão: sim)
        askDownloadLocation = (ud.object(forKey: Keys.askDownloadLocation) as? Bool) ?? true

        // Remove chave legada de monitor (não mais utilizada)
        ud.removeObject(forKey: Keys.alwaysMainMonitor)

        // Garante que a aba selecionada existe na lista
        if selectedTabId == nil || !tabs.contains(where: { $0.id == selectedTabId }) {
            selectedTabId = tabs.first?.id
        }

        // Restaura a pasta de downloads (security-scoped bookmark)
        restoreDownloadFolder()
    }

    /// Migra um valor de porcentagem do UserDefaults, convertendo pixels legados se necessário.
    /// CORRIGIDO: parâmetro `usesHeight` determina se o divisor de migração legada usa
    /// `screen.frame.height` (true) ou `screen.frame.width` (false).
    private func migratePercent(
        key: String,
        legacyKey: String,
        defaultValue: CGFloat,
        legacyMigrationValue: CGFloat,
        clamp: ClosedRange<CGFloat>,
        usesHeight: Bool = false
    ) -> CGFloat {
        let ud = UserDefaults.standard
        if let raw = ud.object(forKey: key) as? Double, raw > 0 {
            let v = CGFloat(raw).clamped(to: clamp)
            return v == legacyMigrationValue ? defaultValue : v
        }
        if let legacyPx = ud.object(forKey: legacyKey) as? Double,
           legacyPx > 0,
           let screen = NSScreen.main {
            let dimension = usesHeight ? screen.frame.height : screen.frame.width
            let ratio = CGFloat(legacyPx) / dimension
            ud.removeObject(forKey: legacyKey)
            return ratio.clamped(to: clamp)
        }
        return defaultValue
    }

    // MARK: - Exportar / Importar

    /// Gera um JSON com todas as configurações e abas.
    public func exportJSON() throws -> Data {
        let snapshot = SettingsSnapshot(
            tabs:                  tabs,
            widthPercent:          Double(widthPercent),
            heightPercent:         Double(heightPercent),
            verticalOffsetPercent: Double(verticalOffsetPercent),
            direction:             direction,
            hotKeyCode:            hotKeyCode,
            hotKeyModifiers:       hotKeyModifiers,
            launchAtLogin:         launchAtLogin
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Importa configurações de um JSON exportado anteriormente.
    /// CORRIGIDO: exibe alerta se a versão do backup for diferente da versão atual,
    /// evitando importações silenciosas de arquivos potencialmente incompatíveis.
    public func importJSON(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)

        if snapshot.appVersion != kAppVersion {
            let alert = NSAlert()
            alert.messageText     = "Versão diferente"
            alert.informativeText = "Este backup foi criado na versão \(snapshot.appVersion). A versão atual é \(kAppVersion). As configurações serão importadas, mas pode haver incompatibilidades."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "Importar assim mesmo")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // SEGURANÇA: descarta abas do backup cuja URL não seja http/https com
        // host (ex.: `file://`, `javascript:`) — um backup adulterado não deve
        // conseguir injetar abas que carreguem esquemas perigosos.
        tabs = snapshot.tabs.compactMap { tab in
            guard let clean = normalizedWebTabURL(from: tab.url.absoluteString) else { return nil }
            var t = tab
            t.url = clean
            return t
        }
        widthPercent          = CGFloat(snapshot.widthPercent).clamped(to: 0.01...1.0)
        heightPercent         = CGFloat(snapshot.heightPercent).clamped(to: 0.01...1.0)
        verticalOffsetPercent = CGFloat(snapshot.verticalOffsetPercent).clamped(to: 0.0...0.5)
        direction             = snapshot.direction
        hotKeyCode            = snapshot.hotKeyCode
        hotKeyModifiers       = snapshot.hotKeyModifiers
        // launchAtLogin não é importado automaticamente — requer ação do usuário
        if selectedTabId == nil || !tabs.contains(where: { $0.id == selectedTabId }) {
            selectedTabId = tabs.first?.id
        }
        saveSettings()
    }
}

// MARK: - Extensão: CGFloat.clamped

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
