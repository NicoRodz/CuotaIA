import Foundation

/// Obtiene el consumo de Codex usando las credenciales locales de la CLI.
final class CodexProvider: QuotaProvider {
    let id = "codex"
    let displayName = "Codex"
    let badge = "X"
    private(set) var availability: Availability = .notInstalled

    /// Estructura de los tokens guardados por Codex.
    private struct Credentials: Decodable {
        /// Datos de acceso asociados a una cuenta de ChatGPT.
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String
        }

        let tokens: Tokens
    }

    /// Estructura parcial de la respuesta de límites de Codex.
    private struct Response: Decodable {
        /// Una ventana de límite expresada como porcentaje usado.
        struct Window: Decodable {
            let used_percent: Double
            let reset_at: Double?
        }

        /// Límites principales y secundarios disponibles para la cuenta.
        struct Limit: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }

        let plan_type: String?
        let rate_limit: Limit?
    }

    /// Estructura de error común que devuelven las APIs HTTP.
    private struct ErrorResponse: Decodable {
        struct APIError: Decodable {
            let message: String?
        }

        let error: APIError?
    }

    /// Consulta la API de uso y convierte su respuesta en un snapshot común.
    func fetch(completion: @escaping (Result<Snapshot, Error>) -> Void) {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            availability = .notInstalled
            completion(.failure(QuotaError("Codex no está instalado")))
            return
        }

        let credentials: Credentials
        do {
            credentials = try JSONDecoder().decode(Credentials.self, from: try Data(contentsOf: file))
        } catch {
            availability = .needsLogin("Credenciales de Codex inválidas")
            completion(.failure(error))
            return
        }

        availability = .ready
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer " + credentials.tokens.access_token, forHTTPHeaderField: "Authorization")
        request.setValue(credentials.tokens.account_id, forHTTPHeaderField: "chatgpt-account-id")

        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(QuotaError("Codex no devolvió una respuesta HTTP")))
                return
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    self.availability = .needsLogin("Inicia sesión en Codex")
                    completion(.failure(QuotaError("Inicia sesión en Codex", statusCode: http.statusCode)))
                    return
                }
                completion(.failure(self.httpError(http, data: data)))
                return
            }
            guard let data = data else {
                completion(.failure(QuotaError("Codex no devolvió datos")))
                return
            }

            do {
                let result = try JSONDecoder().decode(Response.self, from: data)
                completion(
                    .success(
                        Snapshot(
                            plan: result.plan_type,
                            short: self.window(result.rate_limit?.primary_window),
                            week: self.window(result.rate_limit?.secondary_window),
                            fetchedAt: Date(),
                            error: nil
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

    /// Convierte una ventana de la API al modelo común de cuota.
    private func window(_ value: Response.Window?) -> QuotaWindow? {
        guard let value = value else {
            return nil
        }
        return QuotaWindow(
            percent: value.used_percent,
            resetsAt: value.reset_at.map(Date.init(timeIntervalSince1970:))
        )
    }
}
