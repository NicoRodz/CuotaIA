import Foundation

/// Obtiene el consumo de Claude Code usando sus credenciales locales.
final class ClaudeProvider: QuotaProvider {
    let id = "claude"
    let displayName = "Claude Code"
    let badge = "C"
    private(set) var availability: Availability = .notInstalled

    /// Estructura de las credenciales OAuth almacenadas por Claude Code.
    private struct Credentials: Decodable {
        /// Tokens necesarios para consultar la API de uso.
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let subscriptionType: String?
        }

        let claudeAiOauth: OAuth
    }

    /// Estructura parcial de la respuesta de uso de Anthropic.
    private struct Response: Decodable {
        /// Una ventana principal de consumo.
        struct Window: Decodable {
            let utilization: Double
            let resets_at: String?
        }

        /// Un límite adicional desglosado por alcance.
        struct Limit: Decodable {
            /// Alcance asociado a un límite semanal.
            struct Scope: Decodable {
                /// Modelo usado para etiquetar el límite.
                struct Model: Decodable {
                    let display_name: String?
                }

                let model: Model?
            }

            let kind: String
            let percent: Double
            let resets_at: String?
            let scope: Scope?
        }

        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
        /// Verdadero si la respuesta traía la clave `five_hour`, aunque su valor fuera `null`.
        ///
        /// `decodeIfPresent` colapsa "clave ausente" y "clave en null" en el mismo `nil`, y esa
        /// diferencia importa: la ausencia no autoriza a concluir que no hay ventana activa.
        let reportsFiveHour: Bool

        enum CodingKeys: String, CodingKey {
            case five_hour
            case seven_day
            case limits
        }

        /// Decodifica la respuesta conservando si la clave de la ventana corta venía o no.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            five_hour = try container.decodeIfPresent(Window.self, forKey: .five_hour)
            seven_day = try container.decodeIfPresent(Window.self, forKey: .seven_day)
            limits = try container.decodeIfPresent([Limit].self, forKey: .limits)
            reportsFiveHour = container.contains(.five_hour)
        }
    }

    /// Estructura de error común que devuelven las APIs HTTP.
    private struct ErrorResponse: Decodable {
        struct APIError: Decodable {
            let message: String?
        }

        let error: APIError?
    }

    /// Consulta la API de uso y convierte la respuesta en un snapshot común.
    func fetch(completion: @escaping (Result<Snapshot, Error>) -> Void) {
        guard let data = keychainData() else {
            availability = .notInstalled
            completion(.failure(QuotaError("Claude Code no está instalado")))
            return
        }

        let credentials: Credentials
        do {
            credentials = try JSONDecoder().decode(Credentials.self, from: data)
        } catch {
            availability = .needsLogin("Credenciales de Claude inválidas")
            completion(.failure(error))
            return
        }

        if let expiry = credentials.claudeAiOauth.expiresAt,
           Date().timeIntervalSince1970 * 1000 >= expiry {
            availability = .needsLogin("La sesión de Claude venció")
            completion(.failure(QuotaError("La sesión de Claude venció")))
            return
        }

        availability = .ready
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer " + credentials.claudeAiOauth.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(QuotaError("Claude no devolvió una respuesta HTTP")))
                return
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    self.availability = .needsLogin("Inicia sesión en Claude Code")
                    completion(.failure(QuotaError("Inicia sesión en Claude Code", statusCode: http.statusCode)))
                    return
                }
                completion(.failure(self.httpError(http, data: data)))
                return
            }
            guard let data = data else {
                completion(.failure(QuotaError("Claude no devolvió datos")))
                return
            }

            do {
                let value = try JSONDecoder().decode(Response.self, from: data)
                let details = (value.limits ?? []).compactMap { item -> QuotaDetail? in
                    guard item.kind == "weekly_scoped",
                          let name = item.scope?.model?.display_name
                    else {
                        return nil
                    }
                    return QuotaDetail(label: name, percent: item.percent)
                }
                completion(
                    .success(
                        Snapshot(
                            plan: credentials.claudeAiOauth.subscriptionType,
                            short: self.window(value.five_hour),
                            week: self.window(value.seven_day),
                            details: details,
                            fetchedAt: Date(),
                            error: nil,
                            reportsShortWindow: value.reportsFiveHour
                        )
                    )
                )
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Convierte una respuesta HTTP fallida en un error que conserva su contexto útil.
    private func httpError(_ response: HTTPURLResponse, data: Data?) -> QuotaError {
        let body = data.flatMap { try? JSONDecoder().decode(ErrorResponse.self, from: $0) }
        let detail = body?.error?.message
        if response.statusCode == 429 {
            return QuotaError(
                detail ?? "Rate limit",
                statusCode: response.statusCode,
                isRateLimited: true,
                retryAfter: TimeInterval(response.value(forHTTPHeaderField: "Retry-After") ?? "")
            )
        }
        let message = detail.map { "HTTP \(response.statusCode): \($0)" }
            ?? "HTTP \(response.statusCode)"
        return QuotaError(message, statusCode: response.statusCode)
    }

    /// Lee las credenciales del llavero que mantiene Claude Code.
    private func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    /// Convierte una ventana remota al modelo de interfaz.
    private func window(_ value: Response.Window?) -> QuotaWindow? {
        guard let value = value else {
            return nil
        }
        return QuotaWindow(percent: value.utilization, resetsAt: parseDate(value.resets_at))
    }

    /// Interpreta fechas ISO-8601 con o sin milisegundos.
    private func parseDate(_ string: String?) -> Date? {
        guard let string = string else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
