import Foundation

/// Piso para ignorar fluctuaciones de consumo demasiado pequeñas.
private let minimumAnomalyRate = 0.35
/// Ventana máxima entre muestras para calcular una tasa comparable.
private let maximumRateWindowSeconds = 25.0 * 60.0
/// Cantidad mínima de tasas históricas para establecer una línea base confiable.
private let minimumBaselineSamples = 30
/// Cantidad de tasas recientes usadas para suavizar la detección actual.
private let currentRateSampleCount = 3
/// Tiempo entre avisos repetidos del mismo proveedor.
let anomalyCooldownSeconds = 2700.0
private let historyRetentionSeconds = 14.0 * 24.0 * 60.0 * 60.0
private let baselineRetentionSeconds = 7.0 * 24.0 * 60.0 * 60.0
private let minimumRateWindowSeconds = 30.0

/// Una medición de cuota almacenada para calcular tasas de uso.
struct UsageSample: Codable {
    let t: Double
    let s: Double
    let w: Double
}

/// Resultado del detector de consumo anómalo de un proveedor.
struct AnomalyResult {
    let sampleCount: Int
    let median: Double?
    let sigma: Double?
    let threshold: Double
    let currentRate: Double?
    let isFresh: Bool
    let shouldTrigger: Bool
    let multiplier: Double?
}

/// Historial persistente de un proveedor y detector de tasas anómalas.
final class UsageHistory {
    private let file: URL
    private let isReadOnly: Bool
    private(set) var samples: [UsageSample] = []

    /// Carga el historial; el modo solo lectura evita podar o modificar el archivo.
    init(id: String, readOnly: Bool = false) {
        isReadOnly = readOnly
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/CuotaIA",
            isDirectory: true
        )
        file = root.appendingPathComponent("history-" + id + ".jsonl")

        if !readOnly {
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        load()
        if !readOnly && prune() {
            persist()
        }
    }

    /// Reemplaza las muestras con un fixture ordenado para la simulación.
    func load(from source: URL) throws {
        samples = try Self.read(source).sorted { $0.t < $1.t }
    }

    /// Agrega una muestra y solo reescribe el historial si la poda cambió datos.
    func append(short: Double, week: Double, at date: Date = Date()) {
        let sample = UsageSample(t: date.timeIntervalSince1970, s: short, w: week)
        samples.append(sample)

        if prune() {
            persist()
        } else {
            appendToFile(sample)
        }
    }

    /// Calcula la tasa actual, su línea base y si corresponde notificar.
    func result() -> AnomalyResult {
        let entries = rateEntries(samples)
        let all = entries.map(\.rate)
        let baseline = entries
            .filter {
                $0.rate > 0 &&
                    $0.t >= Date().addingTimeInterval(-baselineRetentionSeconds).timeIntervalSince1970
            }
            .map(\.rate)
        let median = baseline.count >= minimumBaselineSamples ? Self.median(baseline) : nil
        let sigma = median.map { center in
            1.4826 * Self.median(baseline.map { abs($0 - center) })
        }
        let threshold = max((median ?? 0) + 3 * (sigma ?? 0), minimumAnomalyRate)
        let current = all.suffix(currentRateSampleCount)
        let currentRate = current.count == currentRateSampleCount
            ? current.reduce(0, +) / Double(current.count)
            : nil
        let isFresh = samples.last.map {
            Date().timeIntervalSince1970 - $0.t < maximumRateWindowSeconds
        } ?? false

        // Evita alertas al reabrir la app con tasas calculadas desde muestras antiguas.
        let shouldTrigger = isFresh && (currentRate.map { $0 > threshold } ?? false)
        let multiplier: Double? = median.flatMap { center in
            guard center > 0, let currentRate = currentRate, currentRate > 0 else {
                return nil
            }
            return currentRate / center
        }

        return AnomalyResult(
            sampleCount: samples.count,
            median: median,
            sigma: sigma,
            threshold: threshold,
            currentRate: currentRate,
            isFresh: isFresh,
            shouldTrigger: shouldTrigger,
            multiplier: multiplier
        )
    }

    /// Carga el archivo local si existe y deja vacío el historial en caso contrario.
    private func load() {
        samples = (try? Self.read(file)) ?? []
    }

    /// Decodifica las líneas válidas de un archivo JSONL.
    private static func read(_ url: URL) throws -> [UsageSample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            try? decoder.decode(UsageSample.self, from: Data(line.utf8))
        }
    }

    /// Elimina muestras fuera de la retención y reporta si cambió el historial.
    @discardableResult
    private func prune() -> Bool {
        let cutoff = Date().addingTimeInterval(-historyRetentionSeconds).timeIntervalSince1970
        let retained = samples.filter { $0.t >= cutoff }
        let didPrune = retained.count != samples.count
        samples = retained
        return didPrune
    }

    /// Añade una única muestra al final para evitar reescribir el historial en cada tick.
    private func appendToFile(_ sample: UsageSample) {
        guard !isReadOnly,
              let data = try? JSONEncoder().encode(sample)
        else {
            return
        }

        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: file.path) else {
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
    }

    /// Reescribe el archivo completo únicamente después de una poda.
    private func persist() {
        let encoder = JSONEncoder()
        let text = samples.compactMap { sample in
            try? String(data: encoder.encode(sample), encoding: .utf8)
        }.joined(separator: "\n") + (samples.isEmpty ? "" : "\n")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Convierte pares consecutivos de muestras en tasas semanales por minuto.
    private func rateEntries(_ samples: [UsageSample]) -> [(t: Double, rate: Double)] {
        guard samples.count > 1 else {
            return []
        }

        return zip(samples.dropFirst(), samples).compactMap { now, previous in
            let seconds = now.t - previous.t
            let minutes = seconds / 60
            let delta = now.w - previous.w
            guard seconds >= minimumRateWindowSeconds,
                  seconds <= maximumRateWindowSeconds,
                  delta >= 0
            else {
                return nil
            }
            return (now.t, delta / minutes)
        }
    }

    /// Obtiene la mediana para una distribución ya disponible en memoria.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
