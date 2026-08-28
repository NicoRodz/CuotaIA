import Foundation

/// Gestiona el LaunchAgent que abre CuotaIA al iniciar sesión.
final class LoginItem {
    private let label = "com.nicorodz.cuotaia"
    private let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/LaunchAgents/com.nicorodz.cuotaia.plist"
    )

    var enabled: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// Crea o elimina el LaunchAgent y aplica el cambio a la sesión actual.
    func setEnabled(_ value: Bool) {
        if value {
            writePlist()
            runLaunchctl(arguments: ["bootstrap", "gui/\(getuid())", path.path])
        } else {
            runLaunchctl(arguments: ["bootout", "gui/\(getuid())", label])
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Escribe el plist con el ejecutable de la app actual.
    private func writePlist() {
        let executable = Bundle.main.executableURL?.path ?? "CuotaIA"
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " +
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\"><dict><key>Label</key><string>\(label)</string>" +
            "<key>ProgramArguments</key><array><string>\(executable)</string></array>" +
            "<key>RunAtLoad</key><true/></dict></plist>"
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? plist.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Ejecuta launchctl e ignora estados ya aplicados por otra operación previa.
    private func runLaunchctl(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}
