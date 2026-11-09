import SwiftUI
import AppKit
import Carbon

extension Notification.Name {
    /// Disparada quando o painel desliza para a tela.
    static let easyBarPanelDidShow = Notification.Name("EasyBarPanelDidShow")
}

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

    // Estrutura da janela + estado do deslize recortado
    private var containerView: NSView?
    private var hostingView:   NSView?
    private var slideDriver:   SlideDriver?
    /// Frame COMPLETO (sem recorte) do painel no último passo do deslize; permite
    /// reverter no meio da animação sem "pulo". `nil` quando em repouso.
    private var lastFullFrame: NSRect?
    private var isSlideAnimating = false

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
        //
        // O NSHostingView agora fica dentro de um contêiner NSView SIMPLES (sem
        // wantsLayer e sem máscara de camada — nada que mexa na composição do
        // WKWebView). Em repouso ele ocupa o contêiner inteiro. Durante o deslize
        // "recortado" (ver runClippedSlide) o contêiner fica menor que o conteúdo e
        // é a própria borda da JANELA que recorta — sem relayout da página.
        let hostingView = NSHostingView(
            rootView: ContentView(settings: settings, controller: self)
        )
        let container = NSView(frame: NSRect(origin: .zero, size: hiddenFrame.size))
        container.autoresizesSubviews = true
        hostingView.frame = container.bounds
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container
        self.containerView = container
        self.hostingView   = hostingView

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

    // MARK: - Supressão temporária do nível flutuante
    //
    // O painel é `.floating` + `.nonactivatingPanel`. Qualquer NSSavePanel /
    // NSOpenPanel apresentado (mesmo como sheet) fica coberto por ele e os
    // cliques do mouse continuam indo para o painel → a janela de salvar
    // parece "travada" (só o campo de texto em foco responde ao teclado).
    // Enquanto um painel do sistema está na tela, baixamos o nível para
    // `.normal` e restauramos depois.

    private var suppressedLevel: NSWindow.Level?

    func suppressFloatingLevel() {
        guard suppressedLevel == nil, let w = window else { return }
        suppressedLevel = w.level
        w.level = .normal
    }

    func restoreFloatingLevel() {
        guard let lvl = suppressedLevel, let w = window else { return }
        w.level = lvl
        suppressedLevel = nil
    }

    // MARK: - Transição (deslizar × desvanecer)
    //
    // "Esconder" = deslizar o painel para fora da borda do monitor principal. Com
    // OUTRO monitor ao lado dessa borda, a área "fora da tela" é o monitor vizinho:
    // o painel desliza para dentro dele e, pior, fica parado ali quando "escondido".
    // Nesse caso o deslize é "recortado": a janela só ocupa a parte que está DENTRO
    // do monitor principal (frame completo ∩ tela) e o conteúdo, em tamanho cheio,
    // é deslocado dentro dela — visualmente é o mesmo painel entrando pela borda.

    /// Frame de "escondido" rente à borda (sem a folga de 20 pt de `hiddenFrame`):
    /// ponto de partida/chegada do deslize recortado.
    static func flushHiddenFrame(for settings: AppSettings, screen: NSScreen) -> NSRect {
        let v = visibleFrame(for: settings, screen: screen)
        let s = screen.frame
        switch settings.direction {
        case .leftToRight: return v.offsetBy(dx: -(v.maxX - s.minX), dy: 0)
        case .rightToLeft: return v.offsetBy(dx:  (s.maxX - v.minX), dy: 0)
        case .topToBottom: return v.offsetBy(dx: 0, dy:  (s.maxY - v.minY))
        case .bottomToTop: return v.offsetBy(dx: 0, dy: -(v.maxY - s.minY))
        }
    }

    /// Janela (recortada) e deslocamento do conteúdo para um frame completo `full`
    /// no passo atual. `window == nil` quando nada está dentro do monitor.
    static func clip(full: NSRect, to screenFrame: NSRect) -> (window: NSRect, contentOrigin: NSPoint)? {
        let v = full.intersection(screenFrame)
        guard !v.isNull, v.width >= 1, v.height >= 1 else { return nil }
        return (v, NSPoint(x: full.minX - v.minX, y: full.minY - v.minY))
    }

    nonisolated static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    nonisolated static func easeIn(_ t: Double)  -> Double { pow(t, 2.2) }

    /// `slide`: desliza a janela inteira para fora da borda (monitor sem vizinho).
    /// `clippedSlide`: mesmo efeito visual, mas a janela é recortada na borda do
    /// monitor principal para nunca aparecer no monitor vizinho.
    enum Transition { case slide, clippedSlide }

    /// Só para testes: força a transição em vez de decidir pelos monitores.
    var transitionOverride: Transition?
    /// Só para testes: multiplica a duração do deslize recortado (1 = normal).
    var animationDurationScale: Double = 1

    /// `true` se o frame "escondido" cai sobre algum outro monitor.
    static func hiddenFrameCollides(_ hidden: NSRect, otherScreens: [NSRect]) -> Bool {
        otherScreens.contains { $0.intersects(hidden) }
    }

    func transition(hidden: NSRect, screen: NSScreen) -> Transition {
        if let forced = transitionOverride { return forced }
        let others = NSScreen.screens.filter { $0 !== screen }.map(\.frame)
        return SlideWindowController.hiddenFrameCollides(hidden, otherScreens: others) ? .clippedSlide : .slide
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
        // A ContentView reativa a aba selecionada se ela foi descarregada por inatividade.
        NotificationCenter.default.post(name: .easyBarPanelDidShow, object: nil)

        switch transition(hidden: hidden, screen: screen) {
        case .slide:
            cancelClippedSlide()
            panel.alphaValue = 1
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

        case .clippedSlide:
            panel.alphaValue = 1
            let from = lastFullFrame
                    ?? SlideWindowController.flushHiddenFrame(for: appSettings, screen: screen)
            runClippedSlide(panel: panel, screen: screen, from: from, to: visible,
                            duration: 0.35 * animationDurationScale, ease: SlideWindowController.easeOut) { [weak panel] in
                panel?.makeKey()
                panel?.makeFirstResponderWebView()
            }
        }
    }

    func hideWindow() {
        guard let panel = window else { return }

        let screen  = SlideWindowController.mainScreen()
        let hidden  = SlideWindowController.hiddenFrame(for: appSettings, screen: screen)
        let visible = SlideWindowController.visibleFrame(for: appSettings, screen: screen)

        isVisible = false

        switch transition(hidden: hidden, screen: screen) {
        case .slide:
            cancelClippedSlide()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration       = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(hidden, display: true)
            } completionHandler: { [weak self, weak panel] in
                // Antes o painel só deslizava e continuava "aberto" fora da borda —
                // com um monitor ao lado ele ficava visível ali. Agora some de verdade.
                // (O usuário pode ter reaberto durante a animação: nesse caso não mexe.)
                guard let self, let panel, !self.isVisible else { return }
                panel.orderOut(nil)
            }

        case .clippedSlide:
            let from = lastFullFrame ?? visible
            let to   = SlideWindowController.flushHiddenFrame(for: appSettings, screen: screen)
            runClippedSlide(panel: panel, screen: screen, from: from, to: to,
                            duration: 0.3 * animationDurationScale, ease: SlideWindowController.easeIn) { [weak self, weak panel] in
                guard let self, let panel, !self.isVisible else { return }
                panel.orderOut(nil)
                // Deixa a janela com o tamanho cheio para o próximo uso.
                panel.setFrame(visible, display: false)
            }
        }
    }

    // MARK: - Deslize recortado (monitor vizinho na borda)

    /// Anima o painel de `from` até `to` (frames COMPLETOS, sem recorte). A cada
    /// quadro a janela vira (frame ∩ monitor principal) e o conteúdo — sempre com
    /// o tamanho cheio — é deslocado dentro dela; quem recorta é a borda da janela.
    /// Resultado: o mesmo "painel entrando pela borda", sem nunca tocar no outro monitor.
    private func runClippedSlide(panel: NSWindow, screen: NSScreen, from: NSRect, to: NSRect,
                                 duration: TimeInterval, ease: @escaping (Double) -> Double,
                                 completion: @escaping () -> Void) {
        guard let container = containerView, let hosting = hostingView else { completion(); return }

        slideDriver?.cancel()
        isSlideAnimating = true
        container.autoresizesSubviews = false        // conteúdo mantém o tamanho cheio
        hosting.frame.size = to.size
        let screenFrame = screen.frame

        let step: (Double) -> Void = { [weak self, weak panel] t in
            guard let self, let panel else { return }
            let e = ease(t)
            let full = NSRect(x: from.minX + (to.minX - from.minX) * e,
                              y: from.minY + (to.minY - from.minY) * e,
                              width: to.width, height: to.height)
            self.lastFullFrame = full
            guard let clipped = SlideWindowController.clip(full: full, to: screenFrame) else {
                if panel.isVisible { panel.orderOut(nil) }   // ainda/já totalmente fora
                return
            }
            hosting.frame = NSRect(origin: clipped.contentOrigin, size: full.size)
            panel.setFrame(clipped.window, display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }

        slideDriver = SlideDriver(screen: screen, duration: duration, step: step) { [weak self] in
            guard let self else { return }
            self.slideDriver      = nil
            self.isSlideAnimating = false
            self.lastFullFrame    = nil
            self.restoreRestingLayout(panelFrame: to)
            completion()
        }
    }

    /// Volta o contêiner ao estado de repouso (conteúdo acompanha o tamanho da janela).
    private func restoreRestingLayout(panelFrame: NSRect) {
        guard let container = containerView, let hosting = hostingView else { return }
        // Só ajusta o frame da janela quando ela ficou mostrada no destino final.
        if isVisible, let panel = window { panel.setFrame(panelFrame, display: true) }
        hosting.frame = container.bounds
        container.autoresizesSubviews = true
    }

    private func cancelClippedSlide() {
        guard slideDriver != nil || lastFullFrame != nil else { return }
        slideDriver?.cancel()
        slideDriver       = nil
        isSlideAnimating  = false
        lastFullFrame     = nil
        if let container = containerView, let hosting = hostingView {
            hosting.frame = container.bounds
            container.autoresizesSubviews = true
        }
    }

    // MARK: - Redimensionamento pelo usuário

    func windowDidResize(_ notification: Notification) {
        // Durante o deslize recortado a largura/altura da janela muda a cada quadro —
        // isso NÃO é o usuário redimensionando e não pode virar configuração salva.
        guard let w = notification.object as? NSWindow, isVisible, !isSlideAnimating else { return }
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


// MARK: - Motor de animação por quadro (deslize recortado)

/// Chama `step(t)` com t∈[0,1] a cada atualização do monitor (CADisplayLink do
/// próprio NSScreen — não depende de a janela estar visível) e `completion` ao fim.
private final class SlideDriver: NSObject {
    private var link: CADisplayLink?
    /// O relógio só começa no PRIMEIRO quadro depois do passo inicial. Na primeira
    /// abertura da sessão o primeiro `orderFront`/render do SwiftUI custa ~100 ms;
    /// se o relógio já estivesse correndo, a animação "pularia" esse começo.
    private var start: CFTimeInterval?
    private let duration: TimeInterval
    private let step: (Double) -> Void
    private let completion: () -> Void

    init(screen: NSScreen, duration: TimeInterval,
         step: @escaping (Double) -> Void, completion: @escaping () -> Void) {
        self.duration   = max(0.01, duration)
        self.step       = step
        self.completion = completion
        super.init()
        step(0)                                       // primeiro quadro já na posição inicial
        let l = screen.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        if start == nil { start = now }
        let t = min(1, (now - start!) / duration)
        step(t)
        if t >= 1 { cancel(); completion() }
    }

    func cancel() { link?.invalidate(); link = nil }
}
