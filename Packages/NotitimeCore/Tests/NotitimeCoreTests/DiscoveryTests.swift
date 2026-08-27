import XCTest
@testable import NotitimeCore

/// FR-004, FR-005, FR-006a : découverte des rôles après duplication du template,
/// listage des sources accessibles, et cas d'une base à plusieurs sources.
final class DiscoveryTests: XCTestCase {

    private func makeClient(_ transport: FixtureTransport) -> NotionClient {
        NotionClient(transport: transport,
                     authorization: StaticAuthorization(),
                     rateLimiter: .forTesting(VirtualTimeSource()))
    }

    private func database(_ id: String, title: String, sources: [(String, String)]) -> String {
        let list = sources.map { #"{"id":"\#($0.0)","name":"\#($0.1)"}"# }.joined(separator: ",")
        return #"{"id":"\#(id)","title":[{"plain_text":"\#(title)"}],"data_sources":[\#(list)]}"#
    }

    /// US1.1 — le template dupliqué donne les trois rôles sans aucune saisie.
    func testTemplateDiscoveryAssignsThreeRolesBySchema() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, NotionAPI.Path.blockChildren("page-tpl") + "?page_size=100",
                                status: 200, json: try Fixture.string("blocks_children_template"))
        await transport.enqueue(.get, NotionAPI.Path.database("db-tasks"), status: 200,
                                json: database("db-tasks", title: "Tâches", sources: [("ds-tasks", "Tâches")]))
        await transport.enqueue(.get, NotionAPI.Path.database("db-time-entries"), status: 200,
                                json: database("db-time-entries", title: "Time Tracker", sources: [("ds-time-entries", "Time Tracker")]))
        await transport.enqueue(.get, NotionAPI.Path.database("db-projects"), status: 200,
                                json: database("db-projects", title: "Projets", sources: [("ds-projects", "Projets")]))
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-tasks"), status: 200,
                                json: try Fixture.string("data_source_tasks_valid"))
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-time-entries"), status: 200,
                                json: try Fixture.string("data_source_time_entries_valid"))
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-projects"), status: 200,
                                json: try Fixture.string("data_source_projects_valid"))

        let outcome = try await RoleDiscovery(client: makeClient(transport))
            .discoverFromTemplate(pageID: "page-tpl")

        XCTAssertEqual(outcome.assigned[.timeEntries]?.dataSourceID, "ds-time-entries")
        XCTAssertEqual(outcome.assigned[.tasks]?.dataSourceID, "ds-tasks")
        XCTAssertEqual(outcome.assigned[.projects]?.dataSourceID, "ds-projects")
        XCTAssertTrue(outcome.sourceChoices.isEmpty)
        XCTAssertTrue(outcome.unresolved.isEmpty, "aucune ambiguïté attendue sur le template")
    }

    /// Le rôle le plus contraint est attribué en premier : la source Time Entries
    /// satisferait aussi le schéma « Tâches » (un titre et un select), et sans cet
    /// ordre elle pourrait rafler le rôle Tâches.
    func testMostConstrainedRoleWinsFirst() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, NotionAPI.Path.blockChildren("page-tpl") + "?page_size=100",
                                status: 200, json: try Fixture.string("blocks_children_template"))
        for (db, title, ds) in [("db-tasks", "Tâches", "ds-tasks"),
                                ("db-time-entries", "Time Tracker", "ds-time-entries"),
                                ("db-projects", "Projets", "ds-projects")] {
            await transport.enqueue(.get, NotionAPI.Path.database(db), status: 200,
                                    json: database(db, title: title, sources: [(ds, title)]))
        }
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-tasks"), status: 200,
                                json: try Fixture.string("data_source_tasks_valid"))
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-time-entries"), status: 200,
                                json: try Fixture.string("data_source_time_entries_valid"))
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-projects"), status: 200,
                                json: try Fixture.string("data_source_projects_valid"))

        let outcome = try await RoleDiscovery(client: makeClient(transport))
            .discoverFromTemplate(pageID: "page-tpl")

        XCTAssertNotEqual(outcome.assigned[.tasks]?.dataSourceID, "ds-time-entries")
        XCTAssertNotEqual(outcome.assigned[.projects]?.dataSourceID, "ds-tasks")
    }

    /// FR-006a — plusieurs sources sur une base : on demande, on n'échoue pas et
    /// on ne choisit pas d'office.
    func testMultipleDataSourcesAskTheUserInsteadOfFailing() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, NotionAPI.Path.blockChildren("page-multi") + "?page_size=100",
                                status: 200,
                                json: #"{"results":[{"id":"db-multi","type":"child_database"}],"has_more":false}"#)
        await transport.enqueue(.get, NotionAPI.Path.database("db-multi"), status: 200,
                                json: database("db-multi", title: "Suivi",
                                               sources: [("ds-time-entries", "2026"), ("ds-projects", "Archives")]))
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-time-entries"), status: 200,
                                json: try Fixture.string("data_source_time_entries_valid"))
        await transport.enqueue(.get, NotionAPI.Path.dataSource("ds-projects"), status: 200,
                                json: try Fixture.string("data_source_projects_valid"))

        let outcome = try await RoleDiscovery(client: makeClient(transport))
            .discoverFromTemplate(pageID: "page-multi")

        XCTAssertEqual(outcome.sourceChoices.count, 1)
        let choice = try XCTUnwrap(outcome.sourceChoices.first)
        XCTAssertEqual(choice.databaseID, "db-multi")
        XCTAssertEqual(choice.sources.map(\.name), ["2026", "Archives"])
        XCTAssertEqual(choice.sources.count, 2, "les deux sources sont présentées")
    }

    /// FR-005 — sans template, on liste les sources accessibles et on pré-sélectionne.
    func testAccessibleSourcesArePreselectedBySchema() async throws {
        let transport = FixtureTransport()
        let results = [try Fixture.string("data_source_tasks_valid"),
                       try Fixture.string("data_source_time_entries_valid")].joined(separator: ",")
        await transport.enqueue(.post, NotionAPI.Path.search, status: 200,
                                json: #"{"results":[\#(results)],"has_more":false}"#)

        let outcome = try await RoleDiscovery(client: makeClient(transport))
            .discoverFromAccessibleSources()

        XCTAssertEqual(outcome.assigned[.timeEntries]?.dataSourceID, "ds-time-entries")
        XCTAssertEqual(outcome.assigned[.tasks]?.dataSourceID, "ds-tasks")
        XCTAssertEqual(outcome.assigned[.tasks]?.databaseID, "db-tasks",
                       "la base conteneur est retenue via parent.database_id")
    }

    func testSearchFiltersOnDataSourceObjects() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.search, status: 200,
                                json: #"{"results":[],"has_more":false}"#)

        _ = try await RoleDiscovery(client: makeClient(transport)).discoverFromAccessibleSources()

        let recorded = await transport.recorded
        let request = try XCTUnwrap(recorded.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        let filter = try XCTUnwrap(body["filter"] as? [String: Any])
        // Depuis 2025-09-03, "database" n'est plus une valeur de filtre acceptée.
        XCTAssertEqual(filter["value"] as? String, "data_source")
        XCTAssertEqual(filter["property"] as? String, "object")
    }

    func testVersionHeaderIsAlwaysSent() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.search, status: 200,
                                json: #"{"results":[],"has_more":false}"#)

        _ = try await RoleDiscovery(client: makeClient(transport)).discoverFromAccessibleSources()

        let recorded = await transport.recorded
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.headers[NotionAPI.Header.version], "2026-03-11")
        XCTAssertEqual(request.headers[NotionAPI.Header.authorization], "Bearer ntn_test")
    }
}
