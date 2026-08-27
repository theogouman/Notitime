import Foundation

/// Client des seuls appels listés par `contracts/notion-api.md`.
///
/// Toute requête traverse le limiteur (FR-029) et porte la version unique.
/// Un `401` déclenche un rafraîchissement puis **un seul** rejeu : un second
/// échec déconnecte, sans jamais vider la file d'envoi (FR-002).
public actor NotionClient {

    private let transport: HTTPTransport
    private let authorization: AuthorizationProvider
    private let rateLimiter: RateLimiter
    private let log: SessionLog?

    public init(transport: HTTPTransport, authorization: AuthorizationProvider,
                rateLimiter: RateLimiter, log: SessionLog? = nil) {
        self.transport = transport
        self.authorization = authorization
        self.rateLimiter = rateLimiter
        self.log = log
    }

    // MARK: - Lecture

    /// Résout les sources d'une base. L'identifiant visible dans l'URL Notion est
    /// celui du conteneur : il ne suffit pas à interroger quoi que ce soit (R-01).
    public func retrieveDatabase(id: String) async throws -> NotionDatabase {
        try await get(NotionAPI.Path.database(id))
    }

    /// Lit le schéma d'une source : c'est `properties` qui fait foi pour la validation.
    public func retrieveDataSource(id: String) async throws -> NotionDataSource {
        try await get(NotionAPI.Path.dataSource(id))
    }

    /// Liste les sources accessibles. `POST /v1/search` n'accepte plus `"database"`
    /// comme valeur de filtre depuis `2025-09-03` : il retourne des `data_source`.
    public func searchDataSources() async throws -> [NotionDataSource] {
        var results: [NotionDataSource] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": ["property": "object", "value": "data_source"],
                                       "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            let page: NotionList<NotionDataSource> = try await post(NotionAPI.Path.search, body: body)
            results.append(contentsOf: page.results)
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        return results
    }

    /// Blocs enfants d'une page : on n'en retient que les `child_database`,
    /// dont l'identifiant de bloc est celui de la base.
    public func childDatabaseIDs(ofPage pageID: String) async throws -> [String] {
        var identifiers: [String] = []
        var cursor: String?
        repeat {
            var path = NotionAPI.Path.blockChildren(pageID) + "?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let page: NotionList<NotionBlock> = try await get(path)
            identifiers.append(contentsOf: page.results.filter(\.isChildDatabase).map(\.id))
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        return identifiers
    }

    // MARK: - Écriture

    /// Ajoute des propriétés manquantes à une source. Appelé uniquement sur
    /// acceptation explicite de l'utilisateur, jamais automatiquement (FR-006).
    public func addProperties(_ properties: [String: Any], toDataSource id: String) async throws {
        let _: NotionDataSource = try await request(.patch, NotionAPI.Path.dataSource(id),
                                                    body: ["properties": properties])
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(.get, path, body: nil)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await request(.post, path, body: body)
    }

    private func request<T: Decodable>(_ method: HTTPRequest.Method, _ path: String,
                                       body: [String: Any]?) async throws -> T {
        let data = try await perform(method, path, body: body, allowRefresh: true)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NotionError.decoding(String(describing: error))
        }
    }

    private func perform(_ method: HTTPRequest.Method, _ path: String,
                         body: [String: Any]?, allowRefresh: Bool) async throws -> Data {
        try await rateLimiter.acquire()

        var headers = [NotionAPI.Header.version: NotionAPI.version]
        headers[NotionAPI.Header.authorization] = "Bearer \(try await authorization.bearerToken())"
        var payload: Data?
        if let body {
            payload = try JSONSerialization.data(withJSONObject: body)
            headers[NotionAPI.Header.contentType] = "application/json"
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: method, path: path,
                                                            headers: headers, body: payload))
        } catch {
            // Aucune réponse : transitoire, et l'issue reste indéterminée pour
            // l'appelant — c'est ce qui imposera la vérification d'idempotence.
            throw NotionError(responseClass: ResponseClassifier.classify(transportError: error),
                              message: String(describing: error))
        }

        let classification = ResponseClassifier.classify(status: response.status,
                                                         retryAfterHeader: response.retryAfter)
        switch classification {
        case .success:
            return response.body

        case .unauthorized where allowRefresh:
            await log?.log(.auth, "401 sur \(path) — tentative de rafraîchissement")
            guard try await authorization.refreshAccessToken() else {
                throw makeError(classification, response)
            }
            // Un seul rejeu : `allowRefresh: false` empêche toute boucle.
            return try await perform(method, path, body: body, allowRefresh: false)

        case .transient(let retryAfter):
            if let retryAfter { await rateLimiter.suspend(for: retryAfter) }
            throw makeError(classification, response)

        default:
            throw makeError(classification, response)
        }
    }

    private func makeError(_ classification: ResponseClass, _ response: HTTPResponse) -> NotionError {
        let body = try? JSONDecoder().decode(NotionErrorBody.self, from: response.body)
        return NotionError(responseClass: classification, status: response.status,
                           code: body?.code ?? body?.error, message: body?.message)
    }
}
