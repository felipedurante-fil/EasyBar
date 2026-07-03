import SwiftUI
import AppKit
import Carbon

// MARK: - NSPanel que aceita eventos de teclado

class SlidePanel: NSPanel {
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async { self.makeFirstResponderWebView() }
    }

    func makeFirstResponderWebView() {
        func findWebView(in view: NSView) -> NSView? {
            if NSStringFromClass(type(of: view)).contains("WKWebView") { return view }
            for sub in view.subviews { if let f = findWebView(in: sub) { return f } }
            return nil
        }
        if let cv = contentView, let wv = findWebView(in: cv) {
            makeFirstResponder(wv)
        }
    }
}

// MARK: - Controlador Principal

class SlideWindowController: NSWindowController, NSWindowDelegate {

    var isVisible:   Bool = false
    var appSettings: AppSettings
    var hotKeyRef:   EventHotKeyRef?

    private static var eventHandlerRef: EventHandlerRef?
    private static weak var sharedInstance: SlideWindowController?

    init(settings: AppSettings) {
        self.appSettings = settings

        // Usa o monitor principal fixo (screens[0] = monitor com barra de menus)
        // NSScreen.main é dinâmico (segue o cursor) — screens.first é sempre o monitor com a barra de menus.
        let screen      = NSScreen.screens.first ?? NSScreen.main!
        let hiddenFrame = SlideWindowController.hiddenFrame(for: settings, screen: screen)

        let panel = SlidePanel(
            contentRect: hiddenFrame,
            styleMask:   [.borderless, .resizable, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.isOpaque                    = false
        panel.backgroundColor             = .clear
        // .floating garante que fica acima de outras janelas normais
        panel.level                       = .floating
        // .canJoinAllSpaces: aparece em TODOS os Spaces do monitor principal.
        // .stationary (anterior) fixava a janela só no Space onde foi criada.
        // .fullScreenAuxiliary: aparece sobre apps em fullscreen.
        panel.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow                   = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate           = false

        super.init(window: panel)
        panel.delegate = self

        // Usa NSHostingView diretamente como contentView do painel.
        // Anteriormente usávamos NSVisualEffectView como contentView e NSHostingView
        // como subview — mas o layer stack (wantsLayer + masksToBounds) do NSVisualEffectView
        // conflitava com o pipeline de composição do WKWebView no macOS 26, deixando
        // o conteúdo em branco. O efeito visual (frosted glass) é obtido via
        // SwiftUI .background(.ultraThinMaterial) em ContentView.
        let hostingView = NSHostingView(
            rootView: ContentView(settings: settings, controller: self)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        SlideWindowController.sharedInstance = self
        installGlobalEventHandlerOnce()
        registerHotKey()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Cleanup
    // CORRIGIDO: sem deinit, o Carbon event handler e o hotkey ficavam registrados
    // indefinidamente. Embora na prática o SlideWindowController viva o tempo inteiro,
    // o deinit defensivo evita vazamentos em reinicializações e testes.

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = SlideWindowController.eventHandlerRef {
            RemoveEventHandler(ref)
            SlideWindowController.eventHandlerRef = nil
        }
    }

    // MARK: - Monitor Principal

    /// Retorna o monitor principal FIXO — aquele com a barra de menus do sistema.
    ///
    /// IMPORTANTE: NSScreen.main é DINÂMICO no macOS — ele muda para o monitor
    /// onde o cursor do mouse está. Por isso usamos NSScreen.screens.first, que é
    /// SEMPRE o monitor com a barra de menus, independente de onde está o foco.
    static func mainScreen() -> NSScreen {
        return NSScreen.screens.first ?? NSScreen.main!
    }

    // MARK: - Cálculo de Frames

    static func resolveSize(for settings: AppSettings, screen: NSScreen) -> (w: CGFloat, h: CGFloat) {
        let w = screen.frame.width  * max(0.01, min(1.0, settings.widthPercent))
        let h = screen.frame.height * max(0.01, min(1.0, settings.heightPercent))
        return (w, h)
    }

    /// Frame oculto — fora da borda do monitor principal.
    static func hiddenFrame(for settings: AppSettings, screen: NSScreen) -> NSRect {
        let s      = screen.frame
        let (w, h) = resolveSize(for: settings, screen: screen)
        let vOff   = s.height * max(0.0, min(0.5, settings.verticalOffsetPercent))

        switch settings.direction {
        case .leftToRight:
            return NSRect(x: s.minX - w - 20,             y: s.maxY - vOff - h, width: w, height: h)
        case .rightToLeft:
            return NSRect(x: s.maxX + 20,                 y: s.maxY - vOff - h, width: w, height: h)
        case .topToBottom:
            return NSRect(x: s.minX + (s.width - w) / 2, y: s.maxY + 20,       width: w, height: h)
        case .bottomToTop:
            return NSRect(x: s.minX + (s.width - w) / 2, y: s.minY - h - 20,   width: w, height: h)
        }
    }

    /// Frame visível — encostado na borda do monitor principal.
    static func visibleFrame(for settings: AppSettings, screen: NSScreen) -> NSRect {
        let s      = screen.frame
        let (w, h) = resolveSize(for: settings, screen: screen)
        let vOff   = s.height * max(0.0, min(0.5, settings.verticalOffsetPercent))

        switch settings.direction {
        case .leftToRight:
            return NSRect(x: s.minX,                      y: s.maxY - vOff - h, width: w, height: h)
        case .rightToLeft:
            return NSRect(x: s.maxX - w,                  y: s.maxY - vOff - h, width: w, height: h)
        case .topToBottom:
            return NSRect(x: s.minX + (s.width - w) / 2, y: s.maxY - h,        width: w, height: h)
        case .bottomToTop:
            return NSRect(x: s.minX + (s.width - w) / 2, y: s.minY,            width: w, height: h)
        }
    }

    // MARK: - Toggle Visibilidade

    @objc func toggleWindow() {
        if isVisible { hideWindow() } else { showWindow() }
    }

    func showWindow() {
        guard let panel = window as? SlidePanel else { return }

        let screen  = SlideWindowController.mainScreen()
        let hidden  = SlideWindowController.hiddenFrame(for: appSettings, screen: screen)
        let visible = SlideWindowController.visibleFrame(for: appSettings, screen: screen)

        isVisible = true

        panel.setFrame(hidden, display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(visible, display: true)
        } completionHandler: {
            panel.makeKey()
            panel.makeFirstResponderWebView()
        }
    }

    func hideWindow() {
        guard let panel = window else { return }

        let screen = SlideWindowController.mainScreen()
        let hidden = SlideWindowController.hiddenFrame(for: appSettings, screen: screen)

        isVisible = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hidden, display: true)
        }
    }

    // MARK: - Redimensionamento pelo usuário

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, isVisible else { return }
        DispatchQueue.main.async {
            let screen = SlideWindowController.mainScreen()
            self.appSettings.widthPercent = max(0.01, min(1.0,
                w.frame.width  / screen.frame.width))
            self.appSettings.heightPercent = max(0.01, min(1.0,
                w.frame.height / screen.frame.height))
            self.appSettings.verticalOffsetPercent = max(0.0, min(0.5,
                (screen.frame.maxY - w.frame.origin.y - w.frame.height) / screen.frame.height))
            self.appSettings.saveSettings()
        }
    }

    // MARK: - Atalho Global de Teclado

    private func installGlobalEventHandlerOnce() {
        guard SlideWindowController.eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                SlideWindowController.sharedInstance?.toggleWindow()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler, 1, &eventSpec, nil,
            &SlideWindowController.eventHandlerRef
        )
    }

    func registerHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4246), id: 1)
        RegisterEventHotKey(
            UInt32(appSettings.hotKeyCode),
            carbonModifiers(from: appSettings.hotKeyModifiers),
            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    /// Converte os modificadores NSEvent (flags raw) para constantes Carbon.
    /// Usa HotKeyModifier centralizado em Models.swift — sem magic numbers.
    private func carbonModifiers(from mods: UInt32) -> UInt32 {
        var carbon: UInt32 = 0
        if mods & HotKeyModifier.option.rawValue  != 0 { carbon |= UInt32(optionKey)  }
        if mods & HotKeyModifier.control.rawValue != 0 { carbon |= UInt32(controlKey) }
        if mods & HotKeyModifier.shift.rawValue   != 0 { carbon |= UInt32(shiftKey)   }
        if mods & HotKeyModifier.command.rawValue != 0 { carbon |= UInt32(cmdKey)      }
        return carbon
    }

    // MARK: - Aplicar Configurações

    func applySettings() {
        registerHotKey()
        let screen = SlideWindowController.mainScreen()
        if isVisible {
            window?.setFrame(
                SlideWindowController.visibleFrame(for: appSettings, screen: screen),
                display: true
            )
        } else {
            window?.setFrame(
                SlideWindowController.hiddenFrame(for: appSettings, screen: screen),
                display: false
            )
        }
    }
}
