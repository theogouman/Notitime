import Foundation

/// Client des trois fonctions serverless. Le contrat est figé dans
/// `contracts/oauth-backend.md` : elles relaient la réponse Notion telle quelle.
public struct BackendClient: Sendable {

    public enum Path {
        public static let token = "/api/notion/token"
        public static let refresh = "/api/notion/refresh"
    }

    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// Échange du code. Le `verifier` ne quitte la mémoire du processus que pour
    /// cet appel : c'est lui, et non la possession du scheme `notitime://`, qui
    /// autorise l'obtention des tokens.
    public func exchange(code: String, state: String, verifier: String) async throws -> NotionAuthorization {
        try await post(Path.token, body: ["code": code, "state": state, "verifier": verifier])
    }

    /// Notion renvoie un nouveau couple : l'application remplace **les deux**.
    public func refresh(refreshToken: String) async throws -> NotionAuthorization {
        try await post(Path.refresh, body: ["refresh_token": refreshToken])
    }

    private func post(_ path: String, body: [String: Any]) async throws -> NotionAuthorization {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let request = HTTPRequest(method: .post, path: path,
                                  headers: [NotionAPI.Header.contentType: "application/json"],
                                  body: payload)

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw NotionError(responseClass: ResponseClassifier.classify(transportError: error),
                              message: String(describing: error))
        }

        let classification = ResponseClassifier.classify(status: response.status,
                                                         retryAfterHeader: response.retryAfter)
        guard classification == .success else {
            let body = try? JSONDecoder().decode(NotionErrorBody.self, from: response.body)
            throw NotionError(responseClass: classification, status: response.status,
                              code: body?.code ?? body?.error, message: body?.message)
        }

        do {
            return try JSONDecoder().decode(NotionAuthorization.self, from: response.body)
        } catch {
            throw NotionError.decoding(String(describing: error))
        }
    }
}
