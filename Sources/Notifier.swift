import Foundation
import UserNotifications

/// Envía avisos de cuota y limita su frecuencia por proveedor.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let defaults = UserDefaults.standard

    /// Solicita permisos y se registra como delegado de las notificaciones.
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Evalúa umbrales fijos y el detector de anomalías para enviar avisos una sola vez.
    func check(provider: QuotaProvider, snapshot: Snapshot, anomaly: AnomalyResult) {
        guard let week = snapshot.week else {
            return
        }

        let resetKey = provider.id + ".reset"
        let reset = week.resetsAt?.timeIntervalSince1970.description ?? "none"
        if defaults.string(forKey: resetKey) != reset {
            defaults.set(reset, forKey: resetKey)
            defaults.removeObject(forKey: provider.id + ".80")
            defaults.removeObject(forKey: provider.id + ".95")
        }

        if week.percent >= 95 && !defaults.bool(forKey: provider.id + ".95") {
            defaults.set(true, forKey: provider.id + ".95")
            send(title: provider.displayName + " al 95%", body: "La cuota semanal está casi agotada.")
        } else if week.percent >= 80 && !defaults.bool(forKey: provider.id + ".80") {
            defaults.set(true, forKey: provider.id + ".80")
            send(title: provider.displayName + " al 80%", body: "La cuota semanal supera el 80%.")
        }

        let highKey = provider.id + ".anomalyHigh"
        guard anomaly.shouldTrigger, let rate = anomaly.currentRate else {
            defaults.set(false, forKey: highKey)
            return
        }

        let last = defaults.double(forKey: provider.id + ".anomaly")
        guard !defaults.bool(forKey: highKey),
              Date().timeIntervalSince1970 - last >= anomalyCooldownSeconds
        else {
            return
        }

        let eta = Int(max(0, week.remaining / rate))
        let multiple = anomaly.multiplier.map {
            String(format: ", %.0f× tu ritmo normal", $0)
        } ?? ""
        send(
            title: provider.displayName + " va rápido",
            body: String(
                format: "%.1f%%/min%@. A este ritmo la cuota semanal se acaba en %d min.",
                rate,
                multiple,
                eta
            )
        )
        defaults.set(Date().timeIntervalSince1970, forKey: provider.id + ".anomaly")
        defaults.set(true, forKey: highKey)
    }

    /// Entrega una notificación nativa o usa AppleScript si el centro falla.
    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                self.fallback(title: title, body: body)
            }
        }
    }

    /// Presenta una notificación de respaldo mediante osascript.
    private func fallback(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        process.arguments = [
            "-e",
            "display notification \"" + escapedBody + "\" with title \"" + escapedTitle + "\""
        ]
        try? process.run()
    }
}
