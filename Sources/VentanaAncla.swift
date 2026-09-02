import Foundation

/// Ancla la ventana rodante de 5 h de Claude Code en una rejilla de horas fija (06/11/16/21).
///
/// Por qué existe: la ventana se ancla en el primer mensaje que se manda después de que expiró la
/// anterior, y lo hace al minuto exacto. Como 24 no es múltiplo de 5, la hora del corte de la tarde
/// depende de a qué hora arrancó el día, y el drift es acumulativo. Con la rejilla clavada, el
/// tercer corte deja una ventana fresca entrando a las 21:00.
///
/// La versión nativa **no consulta el endpoint de cuota**: se alimenta del snapshot que
/// `StatusBarController` ya trae cada 300 s. El endpoint tiene rate limit propio (HTTP 429 con ~11
/// llamadas en 15 min), así que una consulta extra por este camino sería un gasto tonto.
///
/// Coexiste con el script `extras/ventana-ancla/ventana-ancla.sh`: ambos marcan el target anclado en
/// `~/.claude/state/ventana-ancla.state` y respetan las marcas del otro, así que solo uno de los dos
/// dispara el heartbeat de cada target. Queda una ventana de carrera de segundos (los dos podrían
/// comprobar el state antes de que el otro escriba); su costo máximo es un `claude -p ok` con Haiku
/// duplicado, no una rejilla corrida.
final class VentanaAncla {
    /// Clave de `UserDefaults`; sin valor guardado la función queda apagada.
    static let defaultsKey = "ventanaAnclaHabilitada"

    /// Estado del interruptor, compartido entre el panel y este controlador.
    static var habilitada: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Horas de la rejilla, en hora local.
    private let targets = ["06:00", "11:00", "16:00", "21:00"]
    /// Cuánto tiempo después del target se sigue intentando anclar.
    private let graceMinutes = 90
    /// Techo duro al heartbeat, por si `claude -p` se cuelga.
    private let hardTimeout: TimeInterval = 90
    /// Desvío aceptable del reset resultante frente a lo esperado.
    private let toleranceMinutes = 3

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private lazy var stateURL = home.appendingPathComponent(".claude/state/ventana-ancla.state")
    private lazy var resetCacheURL = home.appendingPathComponent(".claude/state/ventana-ancla.reset")
    private lazy var logURL = home.appendingPathComponent(".claude/logs/ventana-ancla.log")

    /// Un anclaje pendiente de verificar con el próximo snapshot.
    private struct Pending {
        let target: String
        let expected: Date
        let after: Date
        /// Hasta cuándo se espera un snapshot que sirva para verificar.
        let deadline: Date
    }

    private var pending: Pending?
    private var isAnchoring = false
    /// El heartbeat en curso, para poder cortarlo si la app se cierra antes de que termine.
    private var running: Process?

    // MARK: - Decisión

    /// Evalúa el snapshot que ya llegó y ancla si toca. Se llama siempre desde el hilo principal.
    func consider(snapshot: Snapshot, now: Date = Date()) {
        guard VentanaAncla.habilitada else { return }
        verifyIfPending(snapshot: snapshot)
        guard !isAnchoring else { return }

        guard let target = currentTarget(now: now) else { return }
        let mark = "\(day(now)) \(target.label)"
        guard !marks().contains(mark) else { return }

        // Anclar exige que la respuesta TRAIGA la clave `five_hour`, igual que hace el script a
        // propósito. Un 200 sin esa clave decodifica como éxito y dejaría `short == nil`: leerlo
        // como "ventana expirada" dispararía un heartbeat a ciegas contra una respuesta que en
        // realidad no dijo nada de la ventana. La clave presente en `null` sí es ventana expirada.
        guard snapshot.reportsShortWindow else {
            log("target=\(target.label) sin-datos respuesta sin five_hour, reintento en el próximo sondeo via=app")
            return
        }

        if let resetsAt = snapshot.short?.resetsAt, resetsAt > now {
            // Ventana viva: el heartbeat no anclaría nada. Se deja el reset en la caché que lee el
            // script para que él tampoco tenga que preguntarle al endpoint.
            cacheReset(resetsAt)
            return
        }

        anchor(target: target, mark: mark, snapshot: snapshot)
    }

    /// Devuelve el target vigente si `now` cae en `[target, target + gracia)`.
    private func currentTarget(now: Date) -> (label: String, date: Date)? {
        for label in targets {
            guard let date = date(day: day(now), clock: label) else { continue }
            if now >= date, now < date.addingTimeInterval(TimeInterval(graceMinutes * 60)) {
                return (label, date)
            }
        }
        return nil
    }

    // MARK: - Anclaje

    /// Lanza `claude -p "ok"` con Haiku y un techo duro de 90 s.
    private func anchor(target: (label: String, date: Date), mark: String, snapshot: Snapshot) {
        guard let binary = VentanaAncla.resolveBinary() else {
            log("target=\(target.label) no encuentro el binario de claude via=app")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "ok", "--model", "haiku", "--no-session-persistence"]
        process.currentDirectoryURL = home
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Una app de barra de menú no hereda el PATH del shell de login, y `claude` es un script que
        // necesita encontrar su propio intérprete. Se le arma un PATH mínimo con el directorio del
        // binario al frente.
        var environment = ProcessInfo.processInfo.environment
        let directory = (binary as NSString).deletingLastPathComponent
        environment["PATH"] = ([directory] + VentanaAncla.searchPaths).joined(separator: ":")
        process.environment = environment

        do {
            try process.run()
        } catch {
            log("target=\(target.label) FALLO al lanzar el heartbeat: \(error.localizedDescription) via=app")
            return
        }

        isAnchoring = true
        running = process
        let queue = DispatchQueue.global(qos: .utility)
        // Techo con SIGTERM antes de SIGKILL (LESSONS L39: nada de kill -9 a la primera). El guardia
        // corre en el hilo principal, igual que el cierre de `waitUntilExit`, así que no puede
        // señalar un proceso que ya terminó y cuyo pid pudo haberse reciclado.
        DispatchQueue.main.asyncAfter(deadline: .now() + hardTimeout) { [weak self] in
            guard let self = self, self.isAnchoring, process.isRunning else { return }
            process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard self.isAnchoring, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
        queue.async { [weak self] in
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                self?.finished(target: target, mark: mark, snapshot: snapshot, status: status)
            }
        }
    }

    /// Corta el heartbeat en curso antes de que la app se cierre.
    ///
    /// El techo de 90 s vive en el main queue, que muere con la app: si el usuario sale con el
    /// heartbeat corriendo, el hijo se queda sin techo y sin padre que lo recoja (LESSONS L39).
    /// Se le manda SIGTERM y se le da hasta 1 s antes del SIGKILL, con el pid vivo en la mano.
    func stop() {
        guard let process = running, process.isRunning else {
            running = nil
            return
        }
        running = nil
        isAnchoring = false
        log("heartbeat cortado por el cierre de la app via=app")
        process.terminate()
        for _ in 0..<20 {
            guard process.isRunning else { return }
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Registra el resultado del heartbeat y marca el target si salió bien.
    private func finished(
        target: (label: String, date: Date),
        mark: String,
        snapshot: Snapshot,
        status: Int32
    ) {
        isAnchoring = false
        running = nil
        guard status == 0 else {
            log(
                "target=\(target.label) FALLO heartbeat rc=\(status) " +
                    "(no se marca el target, reintento en el próximo sondeo) via=app"
            )
            return
        }

        write(mark: mark)
        // Verificar acá exigiría una consulta extra al endpoint. El desvío se mide con el snapshot
        // que ya viene en camino, dentro de los próximos 300 s.
        let expected = target.date.addingTimeInterval(5 * 3600)
        let now = Date()
        pending = Pending(
            target: target.label,
            expected: expected,
            after: now,
            deadline: now.addingTimeInterval(20 * 60)
        )
        log(
            "target=\(target.label) heartbeat-ok esperado=\(clock(expected)) " +
                "semanal=\(percent(snapshot.week?.percent)) (verificación en el próximo sondeo) via=app"
        )
    }

    /// Compara el reset del snapshot nuevo con la hora que la rejilla pedía.
    private func verifyIfPending(snapshot: Snapshot) {
        guard let pending = pending else { return }
        guard let fetchedAt = snapshot.fetchedAt, fetchedAt > pending.after else { return }

        // Un snapshot sin `five_hour`, o con el reset viejo todavía, significa que el endpoint aún
        // no refleja el heartbeat: no sirve para medir el desvío y se espera el siguiente. Sin este
        // filtro, una lectura rezagada se reportaría como ANCLADA-CORRIDA por horas de desvío.
        guard let resetsAt = snapshot.short?.resetsAt, resetsAt > pending.after else {
            if fetchedAt > pending.deadline {
                self.pending = nil
                log(
                    "target=\(pending.target) heartbeat-ok pero el endpoint no devolvió reset " +
                        "(sin verificar) via=app"
                )
            }
            return
        }
        self.pending = nil
        cacheReset(resetsAt)

        let drift = abs(Int(resetsAt.timeIntervalSince(pending.expected)) / 60)
        let usage = "util=\(percent(snapshot.short?.percent)) semanal=\(percent(snapshot.week?.percent))"
        if drift <= toleranceMinutes {
            log("target=\(pending.target) ANCLADA reset=\(clock(resetsAt)) \(usage) via=app")
        } else {
            log(
                "target=\(pending.target) ANCLADA-CORRIDA reset=\(clock(resetsAt)) " +
                    "esperado=\(clock(pending.expected)) desvio=\(drift)min \(usage) via=app"
            )
        }
    }

    // MARK: - Binario

    /// Directorios donde suele vivir `claude`, en el orden en que los prueba el script.
    private static let searchPaths = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    /// Resuelve el ejecutable de `claude`. Una app de barra de menú arranca con un PATH mínimo, así
    /// que buscar por PATH (el `command -v` del script) puede fallar aunque en la terminal funcione.
    static func resolveBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_BIN"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/claude" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Estado y log

    /// Lee las marcas ya escritas, sean de esta app o del script.
    private func marks() -> Set<String> {
        guard let text = try? String(contentsOf: stateURL, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    /// Añade la marca del target anclado y deja el archivo en sus últimas 200 líneas.
    private func write(mark: String) {
        var lines = (try? String(contentsOf: stateURL, encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        guard !lines.contains(mark) else { return }
        lines.append(mark)
        if lines.count > 200 { lines = Array(lines.suffix(200)) }
        ensureDirectory(for: stateURL)
        try? (lines.joined(separator: "\n") + "\n").write(to: stateURL, atomically: true, encoding: .utf8)
    }

    /// Guarda el epoch del reset conocido en la caché que consulta el script antes de pedir cuota.
    private func cacheReset(_ date: Date) {
        ensureDirectory(for: resetCacheURL)
        let epoch = String(Int(date.timeIntervalSince1970))
        try? epoch.write(to: resetCacheURL, atomically: true, encoding: .utf8)
    }

    /// Escribe una línea en el mismo log que usa el script, con su mismo formato.
    ///
    /// Va por `O_APPEND` y no por `seekToEndOfFile()`: el script escribe al MISMO archivo con `>>`,
    /// y un offset calculado antes de que él escriba pisaría su línea. El append del kernel resuelve
    /// el offset en cada `write`, así que las dos fuentes se intercalan sin perder nada. Si el
    /// archivo no se puede abrir, la línea se pierde en silencio: preferible a reemplazar el log
    /// completo, que es la única evidencia de si la rejilla funciona.
    private func log(_ message: String) {
        ensureDirectory(for: logURL)
        let line = "\(timestamp(Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let descriptor = Darwin.open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if result > 0 {
                    written += result
                } else if !(result < 0 && errno == EINTR) {
                    return
                }
            }
        }
    }

    private func ensureDirectory(for url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    // MARK: - Formato

    /// Formateador con locale fijo: la rejilla y el log no deben cambiar con el idioma del sistema.
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let clockFormatter = formatter("HH:mm")
    private static let stampFormatter = formatter("yyyy-MM-dd HH:mm:ss")

    private func day(_ date: Date) -> String { VentanaAncla.dayFormatter.string(from: date) }
    private func clock(_ date: Date) -> String { VentanaAncla.clockFormatter.string(from: date) }
    private func timestamp(_ date: Date) -> String { VentanaAncla.stampFormatter.string(from: date) }

    private func date(day: String, clock: String) -> Date? {
        VentanaAncla.stampFormatter.date(from: "\(day) \(clock):00")
    }

    private func percent(_ value: Double?) -> String {
        guard let value = value else { return "?" }
        return String(format: "%.1f%%", value)
    }
}
