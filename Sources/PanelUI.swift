import AppKit

/// Panel que puede recibir foco sin activar la aplicación anfitriona.
final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }
}

/// Barra de progreso coloreada que representa el consumo de una cuota.
final class ProgressView: NSView {
    var percent: Double = 0 {
        didSet { needsDisplay = true }
    }

    var severity: Severity = .normal {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(origin: .zero, size: bounds.size)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()

        let width = rect.width * CGFloat(min(100, max(0, percent)) / 100)
        switch severity {
        case .normal: NSColor.controlAccentColor.setFill()
        case .warning: NSColor.systemOrange.setFill()
        case .critical: NSColor.systemRed.setFill()
        }
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: rect.height),
            xRadius: 3,
            yRadius: 3
        ).fill()
    }
}

/// Construye y presenta el panel emergente de estado y acciones.
final class PanelUI: NSObject {
    var onRefresh: (() -> Void)?
    private let login = LoginItem()
    private let glass: NSView
    private let content = NSStackView()
    private lazy var panel = QuotaPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var highlightedItem: NSStatusItem?

    override init() {
        glass = PanelUI.makeRoot(glass: true, appearance: nil)
        super.init()
        configureContent()
        configurePanel()
    }

    private init(glass: NSView) {
        self.glass = glass
        super.init()
        configureContent()
    }

    /// Abre el panel centrado y separado del botón de la barra de estado.
    func show(relativeTo button: NSView, item: NSStatusItem) {
        close()
        layoutPanel()
        guard let window = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        guard let screen = window.screen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = panel.frame.size
        let x = min(max(screenRect.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(screenRect.minY - 6 - size.height, visible.minY), visible.maxY - size.height)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        highlightedItem = item
        item.button?.highlight(true)
        installCloseMonitors()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Reconstruye las tarjetas a partir de los snapshots más recientes.
    func update(providers: [QuotaProvider], snapshots: [String: Snapshot]) {
        populate(providers: providers, snapshots: snapshots)
        layoutPanel()
    }

    private func populate(providers: [QuotaProvider], snapshots: [String: Snapshot]) {
        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let shown = providers.filter {
            if case .notInstalled = $0.availability { return false }
            return snapshots[$0.id] != nil
        }
        for (index, provider) in shown.enumerated() {
            guard let snapshot = snapshots[provider.id] else { continue }
            if index > 0 { content.addArrangedSubview(separator()) }
            content.addArrangedSubview(card(provider: provider, snapshot: snapshot))
        }
        if !shown.isEmpty { content.addArrangedSubview(separator()) }
        content.addArrangedSubview(footer())
    }

    /// Captura la jerarquía de vistas del panel sin mostrar ninguna ventana.
    static func render(providers: [QuotaProvider], snapshots: [String: Snapshot], to url: URL) throws
        -> [(url: URL, size: NSSize)] {
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        return try appearances.map { suffix, name in
            let appearance = NSAppearance(named: name)!
            let root = makeRoot(glass: false, appearance: appearance)
            let ui = PanelUI(glass: root)
            ui.populate(providers: providers, snapshots: snapshots)
            let window = NSWindow(
                contentRect: .zero,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.contentView = root
            root.appearance = appearance
            root.layoutSubtreeIfNeeded()
            let size = root.fittingSize
            window.setContentSize(size)
            root.layoutSubtreeIfNeeded()
            let bounds = root.bounds
            guard let rep = root.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw QuotaError("No se pudo crear el bitmap del panel")
            }
            root.cacheDisplay(in: bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw QuotaError("No se pudo codificar el PNG")
            }
            let output = renderURL(from: url, suffix: suffix)
            try png.write(to: output)
            return (output, size)
        }
    }

    private static func renderURL(from url: URL, suffix: String) -> URL {
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(suffix)")
            .appendingPathExtension(ext)
    }

    /// Configura las propiedades compartidas por la raíz de vidrio y la opaca de render.
    private static func makeRoot(glass: Bool, appearance: NSAppearance?) -> NSView {
        let root: NSView
        if glass {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            root = effect
        } else {
            root = NSView()
            root.wantsLayer = true
            if let appearance = appearance {
                root.appearance = appearance
                appearance.performAsCurrentDrawingAppearance {
                    root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
            }
        }
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return root
    }

    private func configureContent() {
        content.orientation = .vertical
        content.spacing = 12
        content.alignment = .leading
        content.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.contentView = glass
    }

    private func layoutPanel() {
        glass.layoutSubtreeIfNeeded()
        let size = glass.fittingSize
        if panel.contentView === glass { panel.setContentSize(size) }
    }

    private func card(provider: QuotaProvider, snapshot: Snapshot) -> NSView {
        let box = vertical(spacing: 10)
        let title = horizontal()
        let name = label(provider.displayName, size: 14, weight: .semibold)
        let plan = label(snapshot.plan ?? "", size: 11, color: .secondaryLabelColor)
        title.addArrangedSubview(name)
        title.addArrangedSubview(expander())
        title.addArrangedSubview(plan)
        box.addArrangedSubview(title)
        box.setCustomSpacing(6, after: title)

        if let status = statusMessage(provider: provider, snapshot: snapshot) {
            box.addArrangedSubview(label(status, size: 11, color: .tertiaryLabelColor))
        }
        if let short = snapshot.short { box.addArrangedSubview(headline(short)) }
        if let week = snapshot.week { box.addArrangedSubview(window("Semana", window: week)) }
        for detail in snapshot.details { box.addArrangedSubview(detailRow(detail)) }
        return box
    }

    /// Resume el último fallo sin ocultar las ventanas obtenidas correctamente.
    private func statusMessage(provider: QuotaProvider, snapshot: Snapshot) -> String? {
        if case .needsLogin = provider.availability {
            return "sesión expirada · abre claude o codex"
        }
        guard let error = snapshot.error else { return nil }
        if error.isRateLimited {
            let seconds = max(0, snapshot.retryAt?.timeIntervalSinceNow ?? 0)
            let minutes = max(1, Int(ceil(seconds / 60)))
            return "sin actualizar · reintenta en \(minutes) min"
        }
        if let fetchedAt = snapshot.fetchedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_CL")
            formatter.dateFormat = "HH:mm"
            return "sin conexión · última lectura \(formatter.string(from: fetchedAt))"
        }
        return "sin conexión"
    }

    private func headline(_ window: QuotaWindow) -> NSView {
        let box = vertical(spacing: 4)
        let line = horizontal()
        let value = label(String(format: "%.0f%%", window.percent), size: 32, weight: .light, mono: true)
        let name = label("5 horas", size: 11, color: .secondaryLabelColor)
        line.addArrangedSubview(value)
        line.addArrangedSubview(expander())
        line.addArrangedSubview(name)
        box.addArrangedSubview(line)
        box.addArrangedSubview(progress(window))
        box.addArrangedSubview(resetLabel(window.resetsAt))
        return box
    }

    private func window(_ name: String, window: QuotaWindow) -> NSView {
        let box = vertical(spacing: 4)
        let line = horizontal()
        line.addArrangedSubview(label(name, size: 12))
        line.addArrangedSubview(expander())
        line.addArrangedSubview(label(String(format: "%.0f%%", window.percent), size: 12, mono: true))
        box.addArrangedSubview(line)
        box.addArrangedSubview(progress(window))
        box.addArrangedSubview(resetLabel(window.resetsAt))
        return box
    }

    private func detailRow(_ detail: QuotaDetail) -> NSView {
        let row = horizontal()
        let name = label(detail.label, size: 11, color: .tertiaryLabelColor)
        let value = label(String(format: "%.0f%%", detail.percent), size: 11, color: .tertiaryLabelColor, mono: true)
        row.addArrangedSubview(name)
        row.addArrangedSubview(expander())
        row.addArrangedSubview(value)
        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let indented = horizontal()
        indented.addArrangedSubview(indent)
        indented.addArrangedSubview(row)
        return indented
    }

    private func progress(_ window: QuotaWindow) -> ProgressView {
        let progress = ProgressView()
        progress.percent = window.percent
        progress.severity = Severity(percent: window.percent)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 6).isActive = true
        progress.widthAnchor.constraint(equalToConstant: 284).isActive = true
        return progress
    }

    private func resetLabel(_ date: Date?) -> NSTextField {
        let reset = label(resetText(date), size: 11, color: .tertiaryLabelColor)
        reset.alignment = .right
        reset.translatesAutoresizingMaskIntoConstraints = false
        reset.widthAnchor.constraint(equalToConstant: 284).isActive = true
        return reset
    }

    private func resetText(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_CL")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "hasta las \(formatter.string(from: date))"
        }
        if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "HH:mm"
            return "hasta mañana \(formatter.string(from: date))"
        }
        formatter.dateFormat = "EEE d MMM"
        return "hasta el \(formatter.string(from: date).replacingOccurrences(of: ".", with: ""))"
    }

    private func footer() -> NSView {
        let box = vertical(spacing: 10)
        let loginRow = horizontal()
        loginRow.addArrangedSubview(label("Abrir al iniciar sesión", size: 12))
        loginRow.addArrangedSubview(expander())
        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleLogin(_:))
        toggle.state = login.enabled ? .on : .off
        loginRow.addArrangedSubview(toggle)
        box.addArrangedSubview(loginRow)

        let actions = horizontal()
        let refresh = button("Actualizar", action: #selector(refresh))
        let quit = button("Salir", action: #selector(quit))
        actions.addArrangedSubview(refresh)
        actions.addArrangedSubview(expander())
        actions.addArrangedSubview(quit)
        box.addArrangedSubview(actions)
        return box
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 284).isActive = true
        return line
    }

    private func vertical(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 284).isActive = true
        return stack
    }

    private func horizontal() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 284).isActive = true
        return stack
    }

    private func expander() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        mono: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .controlAccentColor
        return button
    }

    private func installCloseMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
            [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.close()
                return nil
            }
            if event.window !== self.panel { self.close() }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in self?.close() }
    }

    private func close() {
        panel.orderOut(nil)
        highlightedItem?.button?.highlight(false)
        highlightedItem = nil
        if let globalMonitor = globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver = resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        globalMonitor = nil
        localMonitor = nil
        resignObserver = nil
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Actualizar", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Abrir al iniciar sesión", action: #selector(toggleLogin(_:)), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Salir", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func refresh() { onRefresh?() }

    @objc private func toggleLogin(_ sender: NSButton) {
        login.setEnabled(sender.state == .on)
        sender.state = login.enabled ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
