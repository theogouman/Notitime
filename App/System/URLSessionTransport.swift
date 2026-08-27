import Foundation
import NotitimeCore

/// Implémentation réelle de `HTTPTransport`. La cible applicative est le seul
/// endroit du projet qui connaît `URLSession` : Core n'en dépend jamais, sans quoi
/// aucun test ne pourrait tourner sans réseau (principe VII).
struct URLSessionTransport: HTTPTransport {

    private let session: URLSession
    private let host: URL

    init(session: URLSession = .shared, host: URL = NotionAPI.host) {
        self.session = session
        self.host = host
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.path, relativeTo: host) else {
            throw URLError(.badURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        // La version d'API vient toujours de la constante unique : aucun appelant
        // ne peut la surcharger (contrainte de la constitution).
        urlRequest.setValue(NotionAPI.version, forHTTPHeaderField: NotionAPI.Header.version)
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        // Une erreur levée ici signifie « aucune réponse reçue », donc une issue
        // indéterminée côté file d'envoi : c'est ce qui déclenchera la
        // vérification d'idempotence au réessai (R-06).
        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
