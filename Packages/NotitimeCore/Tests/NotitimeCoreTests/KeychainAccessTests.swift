import XCTest
@testable import NotitimeCore

/// Le trousseau est lu **une fois**, puis gardé en mémoire pour la session.
///
/// Le bundle n'étant pas signé de façon stable, chaque `SecItemCopyMatching`
/// peut déclencher une demande de mot de passe. Une lecture par requête HTTP
/// rendait l'application inutilisable : un simple cycle — chargement des tâches,
/// envoi, réessai — en provoquait une poignée, et les réessais de la file en
/// ajoutaient à chaque tentative.
final class KeychainAccessTests: XCTestCase {

    private let authorizationJSON = """
    {"access_token":"ntn_a1","refresh_token":"ntn_r1","bot_id":"bot-1",
     "workspace_id":"ws-1","workspace_name":"Équipe",
     "owner":{"user":{"id":"user-1","name":"Théo"}}}
    """

    private let taskMapping: [PropertyKey: PropertyRef] = [
        .taskTitle: PropertyRef(id: "title", name: "Name", type: "title")
    ]

    private let entryMapping: [PropertyKey: PropertyRef] = [
        .entryTitle: PropertyRef(id: "title", name: "Name", type: "title"),
        .entryTask: PropertyRef(id: "p-task", name: "Tâches", type: "relation"),
        .entryLocalID: PropertyRef(id: "p-lid", name: "ID", type: "rich_text")
    ]

    private func entry() -> ComposedEntry {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        return ComposedEntry(localID: UUID(), taskPageID: "t-1", title: "T",
                             startedAt: start, endedAt: start.addingTimeInterval(1500),
                             durationMinutes: 25, mode: .pomodoro, outcome: .ranToTerm,
                             shortenReason: nil, subtractedIdleMinutes: 0)
    }

    private func taskPage(_ id: String) -> String {
        #"{"object":"page","id":"\#(id)","properties":{"Name":{"id":"title","type":"title","title":[{"plain_text":"Tâche"}]}}}"#
    }

    /// Un cycle complet au **relancement** — les jetons sont déjà au trousseau :
    /// chargement des tâches paginé, envoi manqué, puis réessai avec vérification
    /// d'idempotence. Six requêtes HTTP, une seule sollicitation du trousseau.
    func testAFullCycleReadsTheKeychainOnce() async throws {
        let transport = FixtureTransport()
        let tokens = CountingTokenStore(access: "ntn_a1", refresh: "ntn_r1")

        let connection = ConnectionService(backend: BackendClient(transport: transport), tokens: tokens)

        let client = NotionClient(transport: transport, authorization: connection,
                                  rateLimiter: .forTesting(VirtualTimeSource()))

        // Chargement des tâches, sur deux pages.
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: #"{"results":[\#(taskPage("t-1"))],"has_more":true,"next_cursor":"c1"}"#)
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: #"{"results":[\#(taskPage("t-2"))],"has_more":false}"#)
        let cache = TaskCache(client: client, mapper: PropertyMapper(map: taskMapping),
                              dataSourceID: "ds-tasks")
        try await cache.refresh()

        let outbox = Outbox(client: client,
                            composer: EntryComposer(mapper: PropertyMapper(map: entryMapping),
                                                    dataSourceID: "ds-te", personUserID: "user-1",
                                                    taskTitleLookup: { _ in "Tâche" }))
        let entry = entry()

        // Premier envoi : la requête se perd, l'issue reste indéterminée.
        struct Offline: Error {}
        await transport.enqueue(.post, NotionAPI.Path.pages, .failure(Offline()))
        let first = await outbox.send(entry)
        guard case .retryLater(let outcome, _) = first, outcome == .indeterminate else {
            return XCTFail("attendu un réessai indéterminé, obtenu \(first)")
        }

        // Réessai : double vérification d'idempotence, puis création.
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-te"), status: 200,
                                json: #"{"results":[],"has_more":false}"#)
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-te"), status: 200,
                                json: #"{"results":[],"has_more":false}"#)
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)
        let second = await outbox.send(entry, afterAttempt: .indeterminate)
        XCTAssertEqual(second, .sent(pageID: "page-1"))

        let requests = await transport.recorded.count
        XCTAssertEqual(requests, 6, "six appels Notion")
        let reads = await tokens.reads
        XCTAssertEqual(reads, 1, "le trousseau n'est lu qu'une fois pour toute la session")
    }

    /// Le jeton rangé à la connexion sert directement : inutile de le relire au
    /// premier appel puisqu'on vient de l'écrire.
    func testConnectingPrimesTheTokenWithoutReadingItBack() async throws {
        let transport = FixtureTransport()
        let tokens = CountingTokenStore()
        await transport.enqueue(.post, BackendClient.Path.token, status: 200, json: authorizationJSON)

        let connection = ConnectionService(backend: BackendClient(transport: transport), tokens: tokens)
        try await connection.connect(code: "c", state: "s", verifier: "v")

        let token = try await connection.bearerToken()

        XCTAssertEqual(token, "ntn_a1")
        let reads = await tokens.accessReads
        XCTAssertEqual(reads, 0, "le jeton vient d'être écrit, on le connaît déjà")
    }

    /// Un rafraîchissement remplace le jeton gardé en mémoire : sans cela, le
    /// cache servirait indéfiniment un jeton expiré, et chaque appel repartirait
    /// en 401.
    func testRefreshReplacesTheCachedToken() async throws {
        let transport = FixtureTransport()
        let tokens = CountingTokenStore(access: "vieux", refresh: "r1")
        await transport.enqueue(.post, BackendClient.Path.refresh, status: 200,
                                json: #"{"access_token":"neuf","refresh_token":"r2","bot_id":"b","workspace_id":"ws-1"}"#)

        let connection = ConnectionService(backend: BackendClient(transport: transport), tokens: tokens)
        let before = try await connection.bearerToken()
        XCTAssertEqual(before, "vieux")

        let refreshed = try await connection.refreshAccessToken()
        XCTAssertTrue(refreshed)

        let after = try await connection.bearerToken()
        XCTAssertEqual(after, "neuf", "le jeton renouvelé prend la place de l'ancien")
        let reads = await tokens.accessReads
        XCTAssertEqual(reads, 1, "une seule lecture : celle d'avant le rafraîchissement")
    }

    /// Une déconnexion oublie le jeton. Le garder en mémoire après un `clear()`
    /// laisserait l'application agir au nom d'un compte déconnecté.
    func testDisconnectForgetsTheCachedToken() async throws {
        let transport = FixtureTransport()
        let tokens = CountingTokenStore(access: "a", refresh: "r")
        let connection = ConnectionService(backend: BackendClient(transport: transport), tokens: tokens)
        _ = try await connection.bearerToken()

        try await connection.disconnect()

        do {
            _ = try await connection.bearerToken()
            XCTFail("plus aucun jeton après déconnexion")
        } catch is ConnectionService.NotConnected {
            // attendu
        }
    }

    /// Une révocation côté Notion efface aussi le jeton gardé en mémoire.
    func testRevocationForgetsTheCachedToken() async throws {
        let transport = FixtureTransport()
        let tokens = CountingTokenStore(access: "a", refresh: "r")
        await transport.enqueue(.post, BackendClient.Path.refresh, status: 400,
                                json: #"{"error":"invalid_grant"}"#)

        let connection = ConnectionService(backend: BackendClient(transport: transport), tokens: tokens)
        _ = try await connection.bearerToken()
        _ = try await connection.refreshAccessToken()

        do {
            _ = try await connection.bearerToken()
            XCTFail("le jeton révoqué ne doit plus servir")
        } catch is ConnectionService.NotConnected {
            // attendu
        }
    }

    /// Deux appels simultanés — la file d'envoi se vide pendant que le cache de
    /// tâches se rafraîchit — ne doivent pas provoquer deux demandes de mot de
    /// passe : la lecture en cours est partagée.
    func testConcurrentCallersShareASingleRead() async throws {
        let transport = FixtureTransport()
        let tokens = CountingTokenStore(access: "a", refresh: "r")
        let connection = ConnectionService(backend: BackendClient(transport: transport), tokens: tokens)

        async let first = connection.bearerToken()
        async let second = connection.bearerToken()
        async let third = connection.bearerToken()
        let tokensRead = try await [first, second, third]

        XCTAssertEqual(tokensRead, ["a", "a", "a"])
        let reads = await tokens.accessReads
        XCTAssertEqual(reads, 1, "une seule lecture partagée par les appelants simultanés")
    }
}
