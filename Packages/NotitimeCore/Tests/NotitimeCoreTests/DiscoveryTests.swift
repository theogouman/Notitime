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

    // MARK: - Duplication asynchrone

    /// Notion crée la page dupliquée de façon asynchrone : au retour de l'OAuth,
    /// elle peut exister tout en étant encore vide. Interroger une seule fois
    /// remontait alors zéro base et menait l'utilisateur dans une impasse.
    func testTemplateDiscoveryRetriesWhileTheCopyIsStillEmpty() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.blockChildren("page-tpl") + "?page_size=100"
        // Deux réponses vides, puis la page complète : les issues sont consommées
        // dans l'ordre d'empilement.
        await transport.enqueue(.get, path, status: 200,
                                json: #"{"object":"list","results":[],"has_more":false}"#)
        await transport.enqueue(.get, path, status: 200,
                                json: #"{"object":"list","results":[],"has_more":false}"#)
        await transport.enqueue(.get, path, status: 200,
                                json: try Fixture.string("blocks_children_template"))
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

        let time = VirtualTimeSource()
        let outcome = try await RoleDiscovery(client: makeClient(transport), time: time)
            .discoverFromTemplate(pageID: "page-tpl")

        XCTAssertEqual(outcome.assigned.count, 3, "la troisième tentative aboutit")
        let calls = await transport.requestCount(.get, path)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(time.sleepCount, 2, "une attente entre chaque tentative")
    }

    /// La page dupliquée peut n'être pas encore visible du tout : un `404`
    /// pendant la fenêtre de copie se réessaie au lieu d'échouer.
    func testTemplateDiscoveryRetriesOnNotFound() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.blockChildren("page-tpl") + "?page_size=100"
        await transport.enqueue(.get, path, status: 404,
                                json: #"{"object":"error","code":"object_not_found"}"#)
        await transport.enqueue(.get, path, status: 200,
                                json: try Fixture.string("blocks_children_template"))
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

        let outcome = try await RoleDiscovery(client: makeClient(transport), time: VirtualTimeSource())
            .discoverFromTemplate(pageID: "page-tpl")

        XCTAssertEqual(outcome.assigned.count, 3)
    }

    /// L'attente est bornée : une page qui reste vide rend un résultat vide —
    /// que l'appelant doit savoir expliquer — plutôt que de tourner sans fin.
    func testTemplateDiscoveryGivesUpAfterItsBudget() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.blockChildren("page-tpl") + "?page_size=100"
        for _ in 0..<RoleDiscovery.templateAttempts {
            await transport.enqueue(.get, path, status: 200,
                                    json: #"{"object":"list","results":[],"has_more":false}"#)
        }

        let outcome = try await RoleDiscovery(client: makeClient(transport), time: VirtualTimeSource())
            .discoverFromTemplate(pageID: "page-tpl")

        XCTAssertTrue(outcome.isEmpty, "aucun rôle, aucun candidat, aucun choix")
        let calls = await transport.requestCount(.get, path)
        XCTAssertEqual(calls, RoleDiscovery.templateAttempts)
    }

    /// Le résultat vide est ce qui déclenche l'explication et les recours à
    /// l'écran : il doit se distinguer d'un résultat simplement incomplet.
    func testOutcomeIsNotEmptyWhenSomethingWasFound() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.search, status: 200,
                                json: #"{"results":[\#(try Fixture.string("data_source_tasks_valid"))],"has_more":false}"#)

        let outcome = try await RoleDiscovery(client: makeClient(transport))
            .discoverFromAccessibleSources()

        XCTAssertFalse(outcome.isEmpty)
    }

    /// Recours de l'écran vide : l'utilisateur doit pouvoir désigner ses bases
    /// à la main, y compris parmi des sources qu'aucun schéma ne valide — c'est
    /// précisément le cas où la détection automatique n'a rien pu proposer.
    func testAllAccessibleSourcesIncludesSourcesThatValidateNoRole() async throws {
        let transport = FixtureTransport()
        let results = [try Fixture.string("data_source_tasks_valid"),
                       try Fixture.string("data_source_time_entries_missing_id")]
            .joined(separator: ",")
        await transport.enqueue(.post, NotionAPI.Path.search, status: 200,
                                json: #"{"results":[\#(results)],"has_more":false}"#)

        let sources = try await RoleDiscovery(client: makeClient(transport)).allAccessibleSources()

        XCTAssertEqual(sources.count, 2, "aucune source n'est masquée par la validation")
        XCTAssertTrue(sources.contains { $0.id == "ds-time-entries-incomplete" },
                      "une source au schéma incomplet reste proposable au choix manuel")
    }

    // MARK: - Template réellement publié

    /// Reproduction exacte du parcours observé en production, qui produisait
    /// `assignés[] ambigus[projects×3]` : les trois sources du template diffusé,
    /// découvertes par la recherche générale. Les trois rôles doivent tomber
    /// juste, sans aucune intervention.
    func testPublishedTemplateAssignsAllThreeRolesThroughSearch() async throws {
        let transport = FixtureTransport()
        let results = [try Fixture.string("data_source_published_template_time_tracker"),
                       try Fixture.string("data_source_published_template_tasks"),
                       try Fixture.string("data_source_published_template_projects")]
            .joined(separator: ",")
        await transport.enqueue(.post, NotionAPI.Path.search, status: 200,
                                json: #"{"results":[\#(results)],"has_more":false}"#)

        let outcome = try await RoleDiscovery(client: makeClient(transport))
            .discoverFromAccessibleSources()

        XCTAssertEqual(outcome.assigned[.timeEntries]?.dataSourceID, "ds-tpl-time-tracker")
        XCTAssertEqual(outcome.assigned[.tasks]?.dataSourceID, "ds-tpl-tasks")
        XCTAssertEqual(outcome.assigned[.projects]?.dataSourceID, "ds-tpl-projects")
        XCTAssertTrue(outcome.unresolved.isEmpty,
                      "plus aucune ambiguïté : obtenu \(outcome.unresolved)")
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
