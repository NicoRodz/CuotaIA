import Foundation

/// Una ventana de cuota, ya sea de cinco horas o semanal.
struct QuotaWindow {
    let percent: Double
    let resetsAt: Date?

    /// Devuelve el porcentaje aún disponible dentro de la ventana.
    var remaining: Double {
        max(0, 100 - percent)
    }
}

/// Severidad visual según cuánto se ha consumido de una cuota.
enum Severity {
    case normal
    case warning
    case critical

    /// Clasifica el porcentaje en los umbrales visuales de la interfaz.
    init(percent: Double) {
        switch percent {
        case ..<75:
            self = .normal
        case ..<90:
            self = .warning
        default:
            self = .critical
        }
    }
}

/// Un desglose adicional que el proveedor quiere exponer, por ejemplo por modelo.
struct QuotaDetail {
    let label: String
    let percent: Double
}

/// Foto del estado de un proveedor en un instante determinado.
struct Snapshot {
    var plan: String?
    var short: QuotaWindow?
    var week: QuotaWindow?
    var details: [QuotaDetail] = []
    var fetchedAt: Date?
    var error: QuotaError?
    var retryAt: Date?

    /// Indica si el proveedor todavía no entregó ninguna ventana de cuota.
    var isEmpty: Bool {
        short == nil && week == nil
    }

    /// Obtiene el porcentaje que manda el color del ícono en la barra.
    var worstPercent: Double {
        max(short?.percent ?? 0, week?.percent ?? 0)
    }
}

/// Estado de instalación y autenticación de un proveedor en este Mac.
enum Availability {
    case ready
    case notInstalled
    case needsLogin(String)
}

/// Contrato común para los proveedores de consumo de cuota.
protocol QuotaProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var badge: String { get }
    var availability: Availability { get }

    /// Obtiene el snapshot actual de cuota del proveedor.
    func fetch(completion: @escaping (Result<Snapshot, Error>) -> Void)
}

/// Error cuyo mensaje está listo para presentarse a una persona.
struct QuotaError: LocalizedError {
    let message: String
    let statusCode: Int?
    let isRateLimited: Bool
    let retryAfter: TimeInterval?

    var errorDescription: String? {
        message
    }

    /// Crea un error de cuota con un texto legible.
    init(
        _ message: String,
        statusCode: Int? = nil,
        isRateLimited: Bool = false,
        retryAfter: TimeInterval? = nil
    ) {
        self.message = message
        self.statusCode = statusCode
        self.isRateLimited = isRateLimited
        self.retryAfter = retryAfter
    }
}
