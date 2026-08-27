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

    /// Modèles de page déclarés par une source, pagination suivie.
    public func dataSourceTemplates(id: String) async throws -> [NotionTemplate] {
        var results: [NotionTemplate] = []
        var cursor: String?
        repeat {
            var path = NotionAPI.Path.dataSourceTemplates(id) + "?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let page: NotionList<NotionTemplate> = try await get(path)
            results.append(contentsOf: page.results)
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        return results
    }

    /// La source déclare-t-elle un modèle par défaut ?
    ///
    /// `template[type]=default` n'est accepté que dans ce cas : le demander
    /// ailleurs fait refuser la création, et l'entrée resterait en file.
    public func hasDefaultTemplate(dataSourceID: String) async throws -> Bool {
        try await dataSourceTemplates(id: dataSourceID).contains(where: \.isDefault)
    }

    /// Profondeur maximale de la descente dans l'arborescence de blocs.
    ///
    /// Un template range volontiers ses bases dans des colonnes, elles-mêmes dans
    /// une bascule ou un encart : trois niveaux sont courants. La borne existe
    /// pour qu'un template inattendu ne déclenche pas une exploration sans fin.
    public static let maxBlockDepth = 5

    /// Identifiants des bases contenues dans une page, **conteneurs de mise en
    /// page traversés** (colonnes, bascules, encarts, listes).
    ///
    /// Deux garde-fous : la descente s'arrête aux pages enfants — ce sont d'autres
    /// pages, les suivre reviendrait à explorer le workspace — et aux bases
    /// elles-mêmes, dont les enfants sont des lignes et non des blocs. Les blocs
    /// déjà vus sont mémorisés : un `synced_block` peut renvoyer vers un ancêtre.
    public func childDatabaseIDs(ofPage pageID: String,
                                 maxDepth: Int = NotionClient.maxBlockDepth) async throws -> [String] {
        var found: [String] = []
        var visited: Set<String> = [pageID]
        try await collectDatabases(in: pageID, depth: 0, maxDepth: maxDepth,
                                   visited: &visited, into: &found)
        return found
    }

    private func collectDatabases(in blockID: String, depth: Int, maxDepth: Int,
                                  visited: inout Set<String>, into found: inout [String]) async throws {
        guard depth <= maxDepth else { return }

        var descendants: [String] = []
        var cursor: String?
        repeat {
            var path = NotionAPI.Path.blockChildren(blockID) + "?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let page: NotionList<NotionBlock> = try await get(path)

            for block in page.results {
                guard visited.insert(block.id).inserted else { continue }
                if block.isChildDatabase {
                    found.append(block.id)
                } else if block.shouldDescend {
                    descendants.append(block.id)
                }
            }
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil

        // Descente après avoir épuisé la pagination du niveau courant : l'ordre
        // des bases trouvées reste celui de la page, de haut en bas.
        for descendant in descendants {
            try await collectDatabases(in: descendant, depth: depth + 1, maxDepth: maxDepth,
                                       visited: &visited, into: &found)
        }
    }

    /// Interroge une source de données. Le corps porte filtres, tri et curseur —
    /// les filtres sont poussés côté API pour ne pas rapatrier toute la base.
    public func queryDataSource(_ dataSourceID: String,
                                body: [String: Any],
                                keepingTrashed: Bool = false) async throws -> NotionList<NotionPage> {
        let page: NotionList<NotionPage> = try await post(NotionAPI.Path.queryDataSource(dataSourceID),
                                                          body: body)
        // Une page en corbeille reste renvoyée par l'API : la filtrer ici évite
        // de la proposer au choix, puis d'y rattacher une entrée de temps.
        // La vérification d'idempotence, elle, veut voir la corbeille : une
        // entrée archivée existe bel et bien et ne doit pas être recréée.
        guard !keepingTrashed else { return page }
        return NotionList(results: page.results.filter { !$0.inTrash },
                          hasMore: page.hasMore, nextCursor: page.nextCursor)
    }

    // MARK: - Écriture

    /// Crée une page dans une source et rend son identifiant.
    ///
    /// L'identifiant rendu est ce qui prouve la création : sans lui, l'entrée ne
    /// peut pas sortir de la file (FR-027).
    public func createPage(_ body: [String: Any]) async throws -> String {
        let created: NotionCreatedPage = try await request(.post, NotionAPI.Path.pages, body: body)
        return created.id
    }

    /// Publie un commentaire sur une page. Best-effort côté appelant (FR-026a),
    /// mais soumis au limiteur comme toute autre requête.
    public func createComment(pageID: String, text: String) async throws {
        let body: [String: Any] = [
            "parent": ["page_id": pageID],
            "rich_text": [["text": ["content": text]]]
        ]
        let _: NotionCreatedComment = try await request(.post, NotionAPI.Path.comments, body: body)
    }

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
                              message: String(describing: error), hadResponse: false)
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
