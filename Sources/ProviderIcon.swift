import AppKit

/// Símbolo del sistema con el que se identifica cada herramienta.
///
/// Vive fuera de la barra y del panel porque los dos dibujan el mismo ícono: la barra como
/// adjunto de texto y el panel como vista, y deben coincidir.
enum ProviderIcon {
    /// Nombres candidatos, ordenados por preferencia, para cada proveedor.
    private static func names(for id: String) -> [String] {
        switch id {
        case "claude":
            return ["sparkle", "sparkles", "asterisk.circle"]
        case "codex":
            return [
                "chevron.left.forwardslash.chevron.right",
                "chevron.left.slash.chevron.right",
                "curlybraces"
            ]
        default:
            return []
        }
    }

    /// Resuelve el primer símbolo que exista en esta versión de macOS.
    static func image(
        for id: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        for name in names(for: id) {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                continue
            }
            image.isTemplate = true
            return image.withSymbolConfiguration(configuration)
        }
        return nil
    }
}
