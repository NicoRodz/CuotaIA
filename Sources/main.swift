import AppKit

/// Punto de entrada de la aplicación de barra de estado.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: StatusBarController?

    /// Crea el controlador al terminar de iniciar la aplicación.
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusBarController(providers: [ClaudeProvider(), CodexProvider()])
    }

    /// Cierra el heartbeat de anclaje: su techo de 90 s vive en el main queue y muere con la app.
    func applicationWillTerminate(_ notification: Notification) {
        status?.prepareForTermination()
    }
}

/// Formatea fechas de respuesta para la salida diagnóstica.
func format(_ date: Date?) -> String {
    guard let date = date else {
        return "-"
    }
    return ISO8601DateFormatter().string(from: date)
}

/// Consulta cada proveedor una vez sin modificar ningún historial local.
func cliOnce() {
    let providers: [QuotaProvider] = [ClaudeProvider(), CodexProvider()]
    let group = DispatchGroup()

    for provider in providers {
        group.enter()
        provider.fetch { result in
            defer {
                group.leave()
            }

            switch result {
            case .success(let snapshot):
                let short = snapshot.short.map {
                    String(format: "%.0f%% %@", $0.percent, format($0.resetsAt))
                } ?? "-"
                let week = snapshot.week.map {
                    String(format: "%.0f%% %@", $0.percent, format($0.resetsAt))
                } ?? "-"
                print(
                    "\(provider.displayName): disponibilidad=ready plan=\(snapshot.plan ?? "-") " +
                        "corta=\(short) semanal=\(week)"
                )
            case .failure(let error):
                switch provider.availability {
                case .notInstalled:
                    print("\(provider.displayName): disponibilidad=notInstalled")
                case .needsLogin(let message):
                    print("\(provider.displayName): disponibilidad=needsLogin \(message)")
                case .ready:
                    if let quotaError = error as? QuotaError, quotaError.isRateLimited {
                        let retryAfter = quotaError.retryAfter.map { String(Int($0)) } ?? "-"
                        print(
                            "\(provider.displayName): disponibilidad=ready " +
                                "error=rate_limit retry_after=\(retryAfter)"
                        )
                        return
                    }
                    print(
                        "\(provider.displayName): disponibilidad=ready " +
                            "error=\(error.localizedDescription)"
                    )
                }
            }

            if case .notInstalled = provider.availability {
                return
            }

            let result = UsageHistory(id: provider.id, readOnly: true).result()
            print(
                "detector \(provider.id): muestras=\(result.sampleCount) " +
                    "mediana=\(result.median.map { String($0) } ?? "-") " +
                    "sigma=\(result.sigma.map { String($0) } ?? "-") " +
                    "umbral=\(result.threshold) " +
                    "actual=\(result.currentRate.map { String($0) } ?? "-")"
            )
        }
    }

    _ = group.wait(timeout: .now() + 30)
}

/// Ejecuta el detector sobre un fixture sin persistir su contenido.
func simulate(_ path: String) -> Int {
    let history = UsageHistory(id: "simulate", readOnly: true)

    do {
        try history.load(from: URL(fileURLWithPath: path))
        let result = history.result()
        print(
            "dispara=\(result.shouldTrigger) muestras=\(result.sampleCount) " +
                "mediana=\(result.median.map { String($0) } ?? "-") " +
                "sigma=\(result.sigma.map { String($0) } ?? "-") " +
                "umbral=\(result.threshold) " +
                "actual=\(result.currentRate.map { String($0) } ?? "-")"
        )

        if result.shouldTrigger,
           let rate = result.currentRate,
           let last = history.samples.last {
            let eta = Int((100 - last.w) / rate)
            let multiple = result.multiplier.map {
                String(format: ", %.0f× tu ritmo normal", $0)
            } ?? ""
            print(
                String(
                    format: "CuotaIA va rápido — %.1f%%/min%@. A este ritmo la cuota semanal " +
                        "se acaba en %d min.",
                    rate,
                    multiple,
                    eta
                )
            )
        }
        return 0
    } catch {
        fputs("simulate error: \(error)\n", stderr)
        return 1
    }
}

/// Proveedor inerte usado exclusivamente por el renderizador de verificación.
final class RenderProvider: QuotaProvider {
    let id: String
    let displayName: String
    let badge: String
    let availability: Availability = .ready

    init(id: String, displayName: String, badge: String) {
        self.id = id
        self.displayName = displayName
        self.badge = badge
    }

    func fetch(completion: @escaping (Result<Snapshot, Error>) -> Void) {
        completion(.failure(QuotaError("Renderizador sin fetch")))
    }
}

/// Escribe una vista determinista del panel para revisar su composición visual.
func render(_ path: String) -> Int {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let now = Date()
    let claude = RenderProvider(id: "claude", displayName: "Claude Code", badge: "C")
    let codex = RenderProvider(id: "codex", displayName: "Codex", badge: "X")
    let snapshots: [String: Snapshot] = [
        "claude": Snapshot(
            plan: "team",
            short: QuotaWindow(percent: 39, resetsAt: now.addingTimeInterval(5 * 3_600)),
            week: QuotaWindow(percent: 67, resetsAt: now.addingTimeInterval(3 * 86_400)),
            details: [QuotaDetail(label: "Fable", percent: 4)]
        ),
        "codex": Snapshot(
            plan: "plus",
            short: QuotaWindow(percent: 4, resetsAt: now.addingTimeInterval(5 * 3_600)),
            week: QuotaWindow(percent: 14, resetsAt: now.addingTimeInterval(3 * 86_400))
        )
    ]
    do {
        let outputs = try PanelUI.render(
            providers: [claude, codex],
            snapshots: snapshots,
            to: URL(fileURLWithPath: path)
        )
        for output in outputs {
            print("\(output.url.path) \(Int(output.size.width))x\(Int(output.size.height)) pt")
        }
        return 0
    } catch {
        fputs("render error: \(error)\n", stderr)
        return 1
    }
}

/// Arranca la app y abre el panel de inmediato, para revisar el vidrio real en pantalla.
func demo() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        delegate.status?.openPanel()
        for window in NSApp.windows where window.isVisible {
            let content = window.contentView.map { String(describing: type(of: $0)) } ?? "-"
            print("ventana=\(type(of: window)) contenido=\(content) frame=\(window.frame)")
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main {
            print("visibleFrame.maxY=\(screen.visibleFrame.maxY)")
        }
        fflush(stdout)
    }
    app.run()
}

let args = CommandLine.arguments
if args.count > 1 && args[1] == "--demo" {
    demo()
} else if args.count > 1 && args[1] == "--once" {
    cliOnce()
} else if args.count == 3 && args[1] == "--simulate" {
    exit(Int32(simulate(args[2])))
} else if args.count == 3 && args[1] == "--render" {
    exit(Int32(render(args[2])))
} else {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.nicorodz.cuotaia"
    let otherInstances = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
    ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !otherInstances.isEmpty {
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
