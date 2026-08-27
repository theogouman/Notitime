import XCTest
@testable import NotitimeCore

/// Découverte des bases dans une page dont la mise en page les imbrique
/// (colonnes, bascules, encarts) — cas courant d'un template réel.
final class BlockDescentTests: XCTestCase {

    private func makeClient(_ transport: FixtureTransport) -> NotionClient {
        NotionClient(transport: transport,
                     authorization: StaticAuthorization(),
                     rateLimiter: .forTesting(VirtualTimeSource()))
    }

    private func children(_ blocks: [(String, String, Bool)]) -> String {
        let items = blocks.map { id, type, hasChildren in
            #"{"object":"block","id":"\#(id)","type":"\#(type)","has_children":\#(hasChildren)}"#
        }.joined(separator: ",")
        return #"{"object":"list","results":[\#(items)],"has_more":false,"next_cursor":null}"#
    }

    private func enqueue(_ transport: FixtureTransport, _ blockID: String,
                         _ blocks: [(String, String, Bool)]) async {
        await transport.enqueue(.get, NotionAPI.Path.blockChildren(blockID) + "?page_size=100",
                                status: 200, json: children(blocks))
    }

    /// Le cas visé : les trois bases sont sous une même page parente, réparties
    /// dans des colonnes.
    func testFindsDatabasesNestedInColumns() async throws {
        let transport = FixtureTransport()
        await enqueue(transport, "page-tpl", [("col-list", "column_list", true),
                                              ("para", "paragraph", false)])
        await enqueue(transport, "col-list", [("col-a", "column", true),
                                              ("col-b", "column", true)])
        await enqueue(transport, "col-a", [("db-tasks", "child_database", true)])
        await enqueue(transport, "col-b", [("db-time-entries", "child_database", true),
                                           ("db-projects", "child_database", true)])

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl")

        XCTAssertEqual(found, ["db-tasks", "db-time-entries", "db-projects"])
    }

    func testDescendsThroughTogglesAndCallouts() async throws {
        let transport = FixtureTransport()
        await enqueue(transport, "page-tpl", [("callout", "callout", true)])
        await enqueue(transport, "callout", [("toggle", "toggle", true)])
        await enqueue(transport, "toggle", [("db-tasks", "child_database", true)])

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl")

        XCTAssertEqual(found, ["db-tasks"])
    }

    /// Une page enfant est une autre page : la suivre reviendrait à explorer le
    /// workspace entier, et ferait remonter des bases sans rapport.
    func testDoesNotFollowChildPages() async throws {
        let transport = FixtureTransport()
        await enqueue(transport, "page-tpl", [("db-tasks", "child_database", true),
                                              ("page-autre", "child_page", true)])
        // Aucune réponse n'est enregistrée pour "page-autre" : si la descente la
        // suivait, le transport lèverait UnexpectedRequest et le test échouerait.

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl")

        XCTAssertEqual(found, ["db-tasks"])
    }

    /// Les enfants d'une base sont ses lignes, pas des blocs : y descendre
    /// paginerait tout le contenu de la base pour rien.
    func testDoesNotDescendIntoDatabases() async throws {
        let transport = FixtureTransport()
        await enqueue(transport, "page-tpl", [("db-tasks", "child_database", true)])

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl")

        XCTAssertEqual(found, ["db-tasks"])
        let calls = await transport.requestCount(.get, NotionAPI.Path.blockChildren("db-tasks") + "?page_size=100")
        XCTAssertEqual(calls, 0)
    }

    func testDepthIsBounded() async throws {
        let transport = FixtureTransport()
        // Chaîne de bascules plus profonde que la borne, avec une base tout au fond.
        await enqueue(transport, "page-tpl", [("n1", "toggle", true)])
        for level in 1...8 {
            await enqueue(transport, "n\(level)", [("n\(level + 1)", "toggle", true)])
        }
        await enqueue(transport, "n9", [("db-profonde", "child_database", true)])

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl", maxDepth: 3)

        XCTAssertTrue(found.isEmpty, "la descente doit s'arrêter à la profondeur demandée")
    }

    func testFindsDatabaseWithinTheDepthBound() async throws {
        let transport = FixtureTransport()
        await enqueue(transport, "page-tpl", [("n1", "toggle", true)])
        await enqueue(transport, "n1", [("n2", "column_list", true)])
        await enqueue(transport, "n2", [("n3", "column", true)])
        await enqueue(transport, "n3", [("db-tasks", "child_database", true)])

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl")

        XCTAssertEqual(found, ["db-tasks"], "trois niveaux d'imbrication restent dans la borne")
    }

    /// Un `synced_block` peut renvoyer vers un ancêtre : sans mémoire des blocs
    /// déjà vus, la descente tournerait en rond.
    func testCycleThroughSyncedBlockDoesNotLoop() async throws {
        let transport = FixtureTransport()
        await enqueue(transport, "page-tpl", [("sync-a", "synced_block", true)])
        await enqueue(transport, "sync-a", [("sync-b", "synced_block", true),
                                            ("db-tasks", "child_database", true)])
        // sync-b renvoie vers sync-a, déjà visité : la descente ne doit pas
        // redemander ses enfants, faute de quoi ce test bouclerait.
        await enqueue(transport, "sync-b", [("sync-a", "synced_block", true)])

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl")

        XCTAssertEqual(found, ["db-tasks"])
        let calls = await transport.requestCount(.get, NotionAPI.Path.blockChildren("sync-a") + "?page_size=100")
        XCTAssertEqual(calls, 1, "un bloc déjà visité n'est pas réexploré")
    }

    func testBlocksWithoutChildrenAreNotFetched() async throws {
        let transport = FixtureTransport()
        await enqueue(transport, "page-tpl", [("para", "paragraph", false),
                                              ("toggle-vide", "toggle", false)])

        let found = try await makeClient(transport).childDatabaseIDs(ofPage: "page-tpl")

        XCTAssertTrue(found.isEmpty)
        let calls = await transport.recorded.count
        XCTAssertEqual(calls, 1, "une seule requête : celle de la page")
    }
}
