import AppKit

/// Coordina proveedores, historial, notificaciones y barra de estado.
final class StatusBarController: NSObject {
    private let baseInterval: TimeInterval = 300
    private let maximumBackoff: TimeInterval = 1800
    private let panelRefreshAge: TimeInterval = 120

    private struct RefreshState {
        var consecutiveFailures = 0
        var retryAt: Date?
        var isFetching = false
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let providers: [QuotaProvider]
    private var snapshots: [String: Snapshot] = [:]
    private var histories: [String: UsageHistory] = [:]
    private var refreshStates: [String: RefreshState] = [:]
    private let panel: PanelUI
    private let notifier = Notifier()
    private var timer: Timer?

    /// Configura los proveedores y agenda actualizaciones incluso con el panel abierto.
    init(providers: [QuotaProvider]) {
        self.providers = providers
        panel = PanelUI()
        super.init()

        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel.onRefresh = { [weak self] in
            self?.requestRefresh(force: true, onlyIfStale: false)
        }

        scheduledRefresh()
        let timer = Timer(
            timeInterval: baseInterval,
            target: self,
            selector: #selector(scheduledRefresh),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Solicita snapshots, respetando el backoff independiente de cada proveedor.
    @objc private func scheduledRefresh() {
        requestRefresh(force: false, onlyIfStale: false)
    }

    private func requestRefresh(force: Bool, onlyIfStale: Bool) {
        for provider in providers {
            var state = refreshStates[provider.id] ?? RefreshState()
            if state.isFetching || state.retryAt.map({ $0 > Date() }) == true {
                continue
            }
            if !force,
               onlyIfStale,
               let fetchedAt = snapshots[provider.id]?.fetchedAt,
               Date().timeIntervalSince(fetchedAt) <= panelRefreshAge {
                continue
            }
            state.isFetching = true
            refreshStates[provider.id] = state
            provider.fetch { [weak self] result in
                DispatchQueue.main.async {
                    self?.received(provider, result)
                }
            }
        }
    }

    /// Guarda el resultado, registra muestras exitosas y atenúa snapshots con fallos.
    private func received(_ provider: QuotaProvider, _ result: Result<Snapshot, Error>) {
        switch result {
        case .success(let snapshot):
            var fresh = snapshot
            fresh.error = nil
            fresh.retryAt = nil
            snapshots[provider.id] = fresh
            refreshStates[provider.id] = RefreshState()
            if let short = snapshot.short, let week = snapshot.week {
                let history = history(for: provider)
                history.append(short: short.percent, week: week.percent)
                notifier.check(provider: provider, snapshot: snapshot, anomaly: history.result())
            }
        case .failure(let error):
            let quotaError = error as? QuotaError ?? QuotaError(error.localizedDescription)
            var state = refreshStates[provider.id] ?? RefreshState()
            state.consecutiveFailures += 1
            state.isFetching = false
            let calculated = min(
                baseInterval * pow(2, Double(state.consecutiveFailures)),
                maximumBackoff
            )
            let delay = quotaError.retryAfter.map { $0 + 5 } ?? calculated
            state.retryAt = Date().addingTimeInterval(delay)
            refreshStates[provider.id] = state
            if var snapshot = snapshots[provider.id] {
                snapshot.error = quotaError
                snapshot.retryAt = state.retryAt
                snapshots[provider.id] = snapshot
            } else {
                snapshots[provider.id] = Snapshot(error: quotaError, retryAt: state.retryAt)
            }
        }

        update()
    }

    /// Obtiene la instancia persistente de historial para un proveedor.
    private func history(for provider: QuotaProvider) -> UsageHistory {
        if let history = histories[provider.id] {
            return history
        }

        let history = UsageHistory(id: provider.id)
        histories[provider.id] = history
        return history
    }

    /// Actualiza la barra y el contenido visible del panel.
    private func update() {
        item.button?.attributedTitle = statusText()
        panel.update(providers: providers, snapshots: snapshots)
    }

    /// Construye la representación compacta de los porcentajes en la barra.
    private func statusText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let shown = providers.filter {
            if case .notInstalled = $0.availability {
                return false
            }
            return true
        }

        guard !shown.isEmpty else {
            return NSAttributedString(string: "CuotaIA", attributes: base)
        }

        for (index, provider) in shown.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "   ", attributes: base))
            }
            let snapshot = snapshots[provider.id]
            result.append(icon(for: provider, base: base))
            result.append(NSAttributedString(string: " ", attributes: base))
            number(snapshot?.short?.percent, snapshot: snapshot, into: result, base: base)
            if let week = snapshot?.week, week.percent >= 75 {
                result.append(NSAttributedString(string: "·", attributes: base))
                number(week.percent, snapshot: snapshot, into: result, base: base)
            }
        }

        return result
    }

    /// Resuelve un símbolo disponible en esta versión de macOS o usa el badge textual.
    private func icon(
        for provider: QuotaProvider,
        base: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard let image = ProviderIcon.image(for: provider.id, pointSize: 11) else {
            return NSAttributedString(string: provider.badge, attributes: base)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -1, width: 12, height: 12)
        return NSAttributedString(attachment: attachment)
    }

    /// Añade un porcentaje con color de severidad o atenuado si falló el último fetch.
    private func number(
        _ percent: Double?,
        snapshot: Snapshot?,
        into output: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any]
    ) {
        guard let percent = percent else {
            output.append(NSAttributedString(string: "--%", attributes: base))
            return
        }

        var attributes = base
        if snapshot?.error != nil {
            attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        } else {
            switch Severity(percent: percent) {
            case .normal:
                break
            case .warning:
                attributes[.foregroundColor] = NSColor.systemOrange
            case .critical:
                attributes[.foregroundColor] = NSColor.systemRed
            }
        }

        output.append(
            NSAttributedString(string: String(format: "%.0f%%", percent), attributes: attributes)
        )
    }

    /// Abre el panel sin pasar por el clic, para inspeccionarlo desde la línea de comandos.
    func openPanel() {
        guard let button = item.button else { return }
        panel.show(relativeTo: button, item: item)
    }

    /// Muestra el menú contextual o abre el panel desde la barra de estado.
    @objc private func clicked(_ sender: Any?) {
        guard let button = item.button, let event = NSApp.currentEvent else {
            return
        }

        if event.type == .rightMouseUp {
            panel.menu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
            return
        }

        // El clic sobre la barra alterna: si el panel ya está abierto, este clic lo cierra.
        // `closedByCurrentClick` cubre el caso en que el propio clic ya lo cerró al quitarle el
        // foco, para que el mouseUp no lo vuelva a abrir de inmediato.
        if panel.isOpen || panel.closedByCurrentClick {
            panel.dismiss()
            return
        }
        requestRefresh(force: false, onlyIfStale: true)
        panel.show(relativeTo: button, item: item)
    }
}
