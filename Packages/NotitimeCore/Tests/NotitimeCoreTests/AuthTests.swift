import XCTest
@testable import NotitimeCore

/// FR-001, FR-002, FR-008 et US1.5 : échange du code, rafraîchissement,
/// révocation, déconnexion — la file d'envoi n'étant jamais vidée au passage.
final class AuthTests: XCTestCase {

    private let authorizationJSON = """
    {"access_token":"ntn_a1","refresh_token":"ntn_r1","bot_id":"bot-1",
     "workspace_id":"ws-1","workspace_name":"Équipe","duplicated_template_id":"tpl-1",
     "owner":{"user":{"id":"user-1","name":"Théo"}}}
    """

    private func makeService(_ transport: FixtureTransport,
                             tokens: InMemoryTokenStore) -> ConnectionService {
        ConnectionService(backend: BackendClient(transport: transport), tokens: tokens)
    }

    func testConnectStoresBothTokensAndKeepsMetadata() async throws {
        let transport = FixtureTransport()
        let tokens = InMemoryTokenStore()
        await transport.enqueue(.post, BackendClient.Path.token, status: 200, json: authorizationJSON)

        let service = makeService(transport, tokens: tokens)
        let result = try await service.connect(code: "c", state: "s", verifier: "v")

        XCTAssertEqual(result.workspaceID, "ws-1")
        XCTAssertEqual(result.duplicatedTemplateID, "tpl-1")
        XCTAssertEqual(result.owner?.user?.id, "user-1")
        let access = try await tokens.accessToken()
        let refresh = try await tokens.refreshToken()
        XCTAssertEqual(access, "ntn_a1")
        XCTAssertEqual(refresh, "ntn_r1")
        let state = await service.state
        XCTAssertEqual(state, .connected(workspaceName: "Équipe", ownerName: "Théo"))
    }

    func testConnectRefusesAnAuthorizationWithoutRefreshToken() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, BackendClient.Path.token, status: 200,
                                json: #"{"access_token":"a","bot_id":"b","workspace_id":"w"}"#)
        let service = makeService(transport, tokens: InMemoryTokenStore())

        // Sans refresh token, la connexion expirerait sans recours : mieux vaut
        // échouer maintenant, avec un message clair, qu'au premier 401.
        do {
            _ = try await service.connect(code: "c", state: "s", verifier: "v")
            XCTFail("la connexion aurait dû être refusée")
        } catch let error as NotionError {
            XCTAssertEqual(error.responseClass, .permanent(.validation))
        }
    }

    /// US1.5 — un 401 déclenche un rafraîchissement puis UN seul rejeu.
    func testUnauthorizedTriggersRefreshThenExactlyOneReplay() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-1"), status: 401)
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-1"), status: 200,
                                json: try Fixture.string("data_source_tasks_valid"))

        let authorization = StaticAuthorization()
        let client = NotionClient(transport: transport, authorization: authorization,
                                  rateLimiter: .forTesting(VirtualTimeSource()))

        let source = try await client.retrieveDataSource(id: "ds-1")

        XCTAssertEqual(source.id, "ds-tasks")
        let refreshCount = await authorization.refreshCount
        XCTAssertEqual(refreshCount, 1)
        let calls = await transport.requestCount(.get, NotionAPI.Path.dataSource("ds-1"))
        XCTAssertEqual(calls, 2, "un seul rejeu, jamais de boucle")
    }

    func testSecondUnauthorizedGivesUpInsteadOfLooping() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-1"), status: 401)
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-1"), status: 401)

        let client = NotionClient(transport: transport, authorization: StaticAuthorization(),
                                  rateLimiter: .forTesting(VirtualTimeSource()))

        do {
            _ = try await client.retrieveDataSource(id: "ds-1")
            XCTFail("un second 401 doit remonter")
        } catch let error as NotionError {
            XCTAssertEqual(error.responseClass, .unauthorized)
        }
        let calls = await transport.requestCount(.get, NotionAPI.Path.dataSource("ds-1"))
        XCTAssertEqual(calls, 2)
    }

    /// US1.5 — révocation dans Notion : on déconnecte, sans toucher à la file.
    func testInvalidGrantDisconnectsWithoutTouchingTheOutbox() async throws {
        let transport = FixtureTransport()
        let tokens = InMemoryTokenStore(access: "a", refresh: "r")
        await transport.enqueue(.post, BackendClient.Path.refresh, status: 400,
                                json: #"{"error":"invalid_grant"}"#)

        var outboxDrained = false
        let service = ConnectionService(backend: BackendClient(transport: transport),
                                        tokens: tokens,
                                        onDisconnect: { outboxDrained = true })

        let refreshed = try await service.refreshAccessToken()

        XCTAssertFalse(refreshed)
        let state = await service.state
        XCTAssertEqual(state, .needsReconnection)
        let access = try await tokens.accessToken()
        XCTAssertNil(access, "les tokens révoqués sont supprimés du Keychain")
        XCTAssertFalse(outboxDrained,
                       "une révocation ne doit jamais vider la file d'envoi (FR-008)")
    }

    /// Une panne réseau pendant un refresh ne doit pas déconnecter : les entrées
    /// restent en file et réessaieront.
    func testTransientRefreshFailureDoesNotDisconnect() async throws {
        let transport = FixtureTransport()
        let tokens = InMemoryTokenStore(access: "a", refresh: "r")
        await transport.enqueue(.post, BackendClient.Path.refresh, .failure(URLError(.notConnectedToInternet)))
        let service = makeService(transport, tokens: tokens)

        do {
            _ = try await service.refreshAccessToken()
            XCTFail("une panne transitoire doit remonter")
        } catch let error as NotionError {
            XCTAssertEqual(error.responseClass, .transient(retryAfter: nil))
        }

        let state = await service.state
        XCTAssertEqual(state, .disconnected, "aucune bascule en needsReconnection")
        let access = try await tokens.accessToken()
        XCTAssertEqual(access, "a", "les tokens sont conservés")
    }

    func testRefreshReplacesBothTokens() async throws {
        let transport = FixtureTransport()
        let tokens = InMemoryTokenStore(access: "old_a", refresh: "old_r")
        await transport.enqueue(.post, BackendClient.Path.refresh, status: 200,
                                json: #"{"access_token":"new_a","refresh_token":"new_r","bot_id":"b","workspace_id":"w"}"#)

        let service = makeService(transport, tokens: tokens)
        let refreshed = try await service.refreshAccessToken()

        XCTAssertTrue(refreshed)
        let access = try await tokens.accessToken()
        let refresh = try await tokens.refreshToken()
        XCTAssertEqual(access, "new_a")
        XCTAssertEqual(refresh, "new_r", "Notion renvoie un nouveau couple : les deux sont remplacés")
    }

    func testDisconnectClearsTokens() async throws {
        let tokens = InMemoryTokenStore(access: "a", refresh: "r")
        let service = makeService(FixtureTransport(), tokens: tokens)

        try await service.disconnect()

        let clearCount = await tokens.clearCount
        XCTAssertEqual(clearCount, 1)
        let state = await service.state
        XCTAssertEqual(state, .disconnected)
    }
}
