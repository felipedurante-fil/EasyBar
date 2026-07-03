import SwiftUI
import AppKit
import ServiceManagement

@main
struct EasyBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Nenhuma cena de janela padrao: o app vive apenas na barra de menus.
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var settings:         AppSettings!
    var windowController: SlideWindowController?
    var statusItem:       NSStatusItem?

    // Janela de configuracoes gerenciada manualmente para nao duplicar
    private var settingsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // IMPORTANTE: deve ser a primeira chamada para garantir que o app
        // nunca apareca na Dock nem no App Switcher (Cmd+Tab).
        NSApp.setActivationPolicy(.accessory)

        self.settings = AppSettings()

        // Garante dimensoes iniciais corretas na primeira execucao
        if settings.widthPercent <= 0  { settings.widthPercent  = 0.70 }
        if settings.heightPercent <= 0 { settings.heightPercent = 0.80 }

        self.windowController = SlideWindowController(settings: self.settings)
        setupMenuBar()
    }

    // MARK: - Barra de Menus

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let img = NSImage(systemSymbolName: "sidebar.left",
                              accessibilityDescription: "EasyBar")
            img?.isTemplate = true
            button.image    = img
            button.toolTip  = "EasyBar"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: "EasyBar", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: "Mostrar / Ocultar",
            action: #selector(toggleAction),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Configurações…",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "Sobre o EasyBar",
            action: #selector(showAboutWindow),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let restartItem = NSMenuItem(
            title: "Reiniciar",
            action: #selector(restartAction),
            keyEquivalent: ""
        )
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(
            title: "Sair",
            action: #selector(quitAction),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Acoes do Menu

    @objc func toggleAction() {
        windowController?.toggleWindow()
    }

    @objc func showSettingsWindow() {
        // Reutiliza a janela se ja estiver aberta
        if let existing = settingsWindowController, existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsWindow(settings: settings, controller: windowController)
        let hosting = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Configurações"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        let wc = NSWindowController(window: window)
        settingsWindowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func restartAction() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", Bundle.main.bundlePath]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc func quitAction() {
        let alert = NSAlert()
        alert.messageText     = "Sair do EasyBar?"
        alert.informativeText = "O aplicativo será encerrado e o atalho de teclado deixará de funcionar."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Sair")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    @objc func showAboutWindow() {
        let alert = NSAlert()
        alert.messageText = "EasyBar"
        alert.informativeText = """
        Pensado e editado por Felipe Durante.
        Código base gerado por Manus AI.

        Versão \(kAppVersion)

        Quer usar o Manus? Acesse pelo link de convite:
        https://manus.im/invitation/Q5BBUEO9MKBUBL
        """
        alert.alertStyle = .informational
        alert.icon       = NSApp.applicationIconImage
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abrir Link de Convite")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "https://manus.im/invitation/Q5BBUEO9MKBUBL") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Ciclo de Vida

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Garante que as configuracoes sao salvas mesmo em force quit ou crash controlado.
    /// O auto-save tem debounce de 500ms — sem isso, alteracoes recentes poderiam ser perdidas.
    func applicationWillTerminate(_ notification: Notification) {
        settings?.saveSettings()
    }
}
