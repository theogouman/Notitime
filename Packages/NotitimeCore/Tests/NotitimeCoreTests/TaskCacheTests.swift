import XCTest
@testable import NotitimeCore

/// T060 à T063 — cache de tâches : filtres poussés côté API, pagination suivie
/// jusqu'au bout, recherche locale, tâches récentes.
final class TaskCacheTests: XCTestCase {

    private let mapping: [PropertyKey: PropertyRef] = [
        .taskTitle: PropertyRef(id: "title", name: "Name", type: "title"),
        .taskStatus: PropertyRef(id: "p-sta", name: "Status", type: "status"),
        .taskAssignee: PropertyRef(id: "p-per", name: "Responsable", type: "people"),
        .taskProject: PropertyRef(id: "p-prj", name: "Projets", type: "relation")
    ]

    private func makeCache(_ transport: FixtureTransport,
                           settings: TaskFilterSettings = TaskFilterSettings()) -> TaskCache {
        TaskCache(client: NotionClient(transport: transport,
                                       authorization: StaticAuthorization(),
                                       rateLimiter: .forTesting(VirtualTimeSource())),
                  mapper: PropertyMapper(map: mapping),
                  dataSourceID: "ds-tasks",
                  settings: settings)
    }

    private func page(_ id: String, _ title: String, status: String = "En cours",
                      assignees: [String] = ["u-1"], inTrash: Bool = false) -> String {
        let people = assignees.map { #"{"object":"user","id":"\#($0)"}"# }.joined(separator: ",")
        return #"""
        {"object":"page","id":"\#(id)","in_trash":\#(inTrash),"properties":{
          "Name":{"id":"title","type":"title","title":[{"plain_text":"\#(title)"}]},
          "Status":{"id":"p-sta","type":"status","status":{"name":"\#(status)"}},
          "Responsable":{"id":"p-per","type":"people","people":[\#(people)]},
          "Projets":{"id":"p-prj","type":"relation","relation":[]}}}
        """#.replacingOccurrences(of: "\n", with: "")
    }

    private func response(_ pages: [String], hasMore: Bool = false, cursor: String? = nil) -> String {
        let next = cursor.map { #""\#($0)""# } ?? "null"
        return #"{"results":[\#(pages.joined(separator: ","))],"has_more":\#(hasMore),"next_cursor":\#(next)}"#
    }

    // MARK: - T060 : pagination et filtres

    /// FR-009 — la pagination est suivie jusqu'à `has_more` faux, sans plafond.
    func testPaginationIsFollowedWithoutCap() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.queryDataSource("ds-tasks")
        for index in 0..<4 {
            await transport.enqueue(.post, path, status: 200,
                                    json: response([page("t-\(index)", "Tâche \(index)")],
                                                   hasMore: index < 3,
                                                   cursor: index < 3 ? "c\(index)" : nil))
        }

        let cache = makeCache(transport)
        try await cache.refresh()

        let tasks = await cache.tasks
        XCTAssertEqual(tasks.count, 4)
        let calls = await transport.requestCount(.post, path)
        XCTAssertEqual(calls, 4)
    }

    /// Les filtres partent côté API : rapatrier toute la base pour filtrer en
    /// local gaspillerait le quota et le temps de démarrage.
    func testFiltersArePushedToTheAPI() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"),
                                status: 200, json: response([]))
        var settings = TaskFilterSettings()
        settings.doneStatusValues = ["Terminé", "Annulé"]
        settings.currentUserID = "u-1"
        settings.includeUnassigned = false

        try await makeCache(transport, settings: settings).refresh()

        let recorded = await transport.recorded
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded[0].body ?? Data())
                                    as? [String: Any])
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: body),
                                as: UTF8.self)
        XCTAssertTrue(serialized.contains("does_not_equal"), "obtenu : \(serialized)")
        XCTAssertTrue(serialized.contains("Terminé"))
        XCTAssertTrue(serialized.contains("Annulé"))
        XCTAssertTrue(serialized.contains("u-1"), "le filtre Personne est poussé")
    }

    /// Une page en corbeille reste renvoyée par l'API : la proposer mènerait à
    /// rattacher une entrée de temps à une tâche supprimée.
    func testTrashedPagesAreExcluded() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([page("t-1", "Vivante"),
                                                page("t-2", "Supprimée", inTrash: true)]))

        let cache = makeCache(transport)
        try await cache.refresh()

        let tasks = await cache.tasks
        XCTAssertEqual(tasks.map(\.title), ["Vivante"])
    }

    // MARK: - T061 : statut et personne

    /// US3.2 — sans filtre Personne, les tâches non assignées sont proposées.
    func testUnassignedTasksAreIncludedWhenConfigured() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([]))
        var settings = TaskFilterSettings()
        settings.currentUserID = "u-1"
        settings.includeUnassigned = true

        try await makeCache(transport, settings: settings).refresh()

        let recorded = await transport.recorded
        let serialized = String(decoding: recorded[0].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(serialized.contains("is_empty"),
                      "les tâches sans responsable doivent être demandées aussi")
    }

    /// FR-010 — les valeurs terminées sont configurables, pas codées en dur.
    func testDoneValuesAreConfigurable() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([]))
        var settings = TaskFilterSettings()
        settings.doneStatusValues = ["Livré"]

        try await makeCache(transport, settings: settings).refresh()

        let recorded = await transport.recorded
        let serialized = String(decoding: recorded[0].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(serialized.contains("Livré"))
        XCTAssertFalse(serialized.contains("Terminé"), "aucune valeur par défaut codée en dur")
    }

    // MARK: - T062 : recherche locale

    /// FR-013 — insensible à la casse et aux accents, et **sans requête réseau**.
    func testSearchIsLocalCaseAndDiacriticInsensitive() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([page("t-1", "Refonte FACTURATION"),
                                                page("t-2", "Révision légale"),
                                                page("t-3", "Autre chose")]))
        let cache = makeCache(transport)
        try await cache.refresh()
        let before = await transport.recorded.count

        let found = await cache.search("facturation")
        let accents = await cache.search("REVISION LEGALE")

        XCTAssertEqual(found.map(\.title), ["Refonte FACTURATION"])
        XCTAssertEqual(accents.map(\.title), ["Révision légale"])
        let after = await transport.recorded.count
        XCTAssertEqual(before, after, "la recherche ne doit émettre aucune requête")
    }

    func testEmptySearchReturnsEverything() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([page("t-1", "Une"), page("t-2", "Deux")]))
        let cache = makeCache(transport)
        try await cache.refresh()

        let found = await cache.search("   ")

        XCTAssertEqual(found.count, 2)
    }

    // MARK: - T063 : tâches récentes

    /// FR-014 — les récentes remontent en tête, hors du filtre courant.
    func testRecentTasksComeFirst() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([page("t-1", "Une"), page("t-2", "Deux"),
                                                page("t-3", "Trois")]))
        let cache = makeCache(transport)
        try await cache.refresh()

        await cache.noteUse(of: "t-3")
        await cache.noteUse(of: "t-2")

        let recents = await cache.recentTasks()
        XCTAssertEqual(recents.map(\.id), ["t-2", "t-3"], "la plus récente en tête")
    }

    /// Une tâche terminée depuis n'a plus à figurer dans les récentes.
    func testRecentTasksHideCompletedOnes() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.queryDataSource("ds-tasks")
        await transport.enqueue(.post, path, status: 200,
                                json: response([page("t-1", "Une"), page("t-2", "Deux")]))
        // Au rafraîchissement suivant, t-2 a disparu du résultat filtré.
        await transport.enqueue(.post, path, status: 200, json: response([page("t-1", "Une")]))

        let cache = makeCache(transport)
        try await cache.refresh()
        await cache.noteUse(of: "t-2")
        try await cache.refresh()

        let recents = await cache.recentTasks()
        XCTAssertTrue(recents.isEmpty, "une tâche hors du filtre ne peut plus être proposée")
    }

    /// FR-014 — cinq par défaut.
    func testRecentTasksAreCappedAtTheConfiguredCount() async throws {
        let transport = FixtureTransport()
        let pages = (1...8).map { page("t-\($0)", "Tâche \($0)") }
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response(pages))
        let cache = makeCache(transport)
        try await cache.refresh()

        for index in 1...8 { await cache.noteUse(of: "t-\(index)") }

        let recents = await cache.recentTasks()
        XCTAssertEqual(recents.count, TaskFilterSettings().recentTaskCount)
    }

    /// SC-006 — le cache reste consultable quand Notion est injoignable, et la
    /// date de dernière synchronisation réussie est conservée.
    func testCacheSurvivesAFailedRefresh() async throws {
        struct Offline: Error {}
        let transport = FixtureTransport()
        let path = NotionAPI.Path.queryDataSource("ds-tasks")
        await transport.enqueue(.post, path, status: 200, json: response([page("t-1", "Une")]))
        await transport.enqueue(.post, path, .failure(Offline()))

        let cache = makeCache(transport)
        try await cache.refresh()
        let syncedAt = await cache.lastSuccessfulSync

        do {
            try await cache.refresh()
            XCTFail("le second rafraîchissement doit échouer")
        } catch {}

        let tasks = await cache.tasks
        XCTAssertEqual(tasks.count, 1, "le cache reste utilisable")
        let stillSyncedAt = await cache.lastSuccessfulSync
        XCTAssertEqual(syncedAt, stillSyncedAt, "la date de dernière réussite ne bouge pas")
    }
}

/// Un cache de tâches n'est valable que pour la base qui l'a bâti.
///
/// Le défaut : le cache était construit au premier chargement, puis réutilisé
/// jusqu'à la fin du processus. Changer la base Tâches — depuis les réglages,
/// par une reconnexion ou par une revalidation — n'atteignait jamais le cache,
/// qui continuait d'interroger l'ancienne source. Aucune erreur, aucune tâche,
/// et une liaison pourtant correcte en base : rien ne permettait de voir que la
/// question était posée à la mauvaise base.
final class TaskCacheRebindTests: XCTestCase {

    private let map: [PropertyKey: PropertyRef] = [
        .taskTitle: PropertyRef(id: "title", name: "Name", type: "title")
    ]

    private func page(_ id: String, _ title: String) -> String {
        #"""
        {"object":"page","id":"\#(id)","properties":{
          "Name":{"id":"title","type":"title","title":[{"plain_text":"\#(title)"}]}}}
        """#.replacingOccurrences(of: "\n", with: "")
    }

    private func cache(_ transport: FixtureTransport, source: String) -> TaskCache {
        TaskCache(client: NotionClient(transport: transport,
                                       authorization: StaticAuthorization(),
                                       rateLimiter: .forTesting(VirtualTimeSource())),
                  mapper: PropertyMapper(map: map),
                  dataSourceID: source)
    }

    func testRebindingChangesTheSourceQueried() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-ancienne"), status: 200,
                                json: #"{"results":[\#(page("t-1", "Ancienne"))],"has_more":false}"#)
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-nouvelle"), status: 200,
                                json: #"{"results":[\#(page("t-2", "Nouvelle"))],"has_more":false}"#)

        let cache = cache(transport, source: "ds-ancienne")
        try await cache.refresh()
        let first = await cache.tasks
        XCTAssertEqual(first.map(\.title), ["Ancienne"])

        await cache.rebind(dataSourceID: "ds-nouvelle", mapper: PropertyMapper(map: map))
        try await cache.refresh()

        let reloaded = await cache.tasks
        XCTAssertEqual(reloaded.map(\.title), ["Nouvelle"])
        let count = await transport.requestCount(.post, NotionAPI.Path.queryDataSource("ds-nouvelle"))
        XCTAssertEqual(count, 1, "la seconde lecture doit viser la nouvelle base")
    }

    /// Les tâches de l'ancienne base disparaissent immédiatement : les garder
    /// afficherait des tâches qui n'existent pas dans celle qu'on vient de lier.
    func testRebindingEmptiesWhatCameFromTheFormerSource() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-ancienne"), status: 200,
                                json: #"{"results":[\#(page("t-1", "Ancienne"))],"has_more":false}"#)

        let cache = cache(transport, source: "ds-ancienne")
        try await cache.refresh()
        await cache.rebind(dataSourceID: "ds-nouvelle", mapper: PropertyMapper(map: map))

        let remaining = await cache.tasks
        XCTAssertTrue(remaining.isEmpty)
        let stamp = await cache.lastSuccessfulSync
        XCTAssertNil(stamp, "la dernière synchronisation ne concernait pas cette base")
    }

    /// Relier la même base ne doit rien effacer : le rafraîchissement passe par
    /// là à chaque chargement, et viderait la liste à chaque fois.
    func testRebindingToTheSameSourceKeepsEverything() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-a"), status: 200,
                                json: #"{"results":[\#(page("t-1", "Une"))],"has_more":false}"#)

        let cache = cache(transport, source: "ds-a")
        try await cache.refresh()
        await cache.rebind(dataSourceID: "ds-a", mapper: PropertyMapper(map: map))

        let kept = await cache.tasks
        XCTAssertEqual(kept.map(\.title), ["Une"])
        let synced = await cache.lastSuccessfulSync
        XCTAssertNotNil(synced)
    }
}
