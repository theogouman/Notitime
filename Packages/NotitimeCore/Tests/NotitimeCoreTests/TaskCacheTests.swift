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

    // MARK: - Marquer une tâche terminée (US3)

    /// La valeur écrite vient du groupe « terminé » du schéma, pas d'un libellé
    /// codé en dur : une base en anglais ou un statut renommé restent servis.
    func testMarkingDoneWritesTheSchemaValue() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.patch, "/v1/pages/t-1", status: 200,
                                json: #"{"object":"page","id":"t-1"}"#)
        let cache = TaskCache(client: NotionClient(transport: transport,
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: [
                                .taskTitle: PropertyRef(id: "title", name: "Name", type: "title"),
                                .taskStatus: PropertyRef(id: "p-sta", name: "Status", type: "status",
                                                         options: ["À faire", "Terminé", "Annulé"],
                                                         completeOptions: ["Terminé", "Annulé"])
                              ]),
                              dataSourceID: "ds-tasks",
                              settings: TaskFilterSettings())

        let written = try await cache.markDone("t-1")

        XCTAssertEqual(written, "Terminé")
        let recorded = await transport.recorded
        let body = try XCTUnwrap(recorded.last?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        let status = try XCTUnwrap(properties["Status"] as? [String: Any])
        XCTAssertEqual((status["status"] as? [String: Any])?["name"] as? String, "Terminé")
    }

    /// Une tâche terminée n'a plus sa place dans une liste de tâches à faire :
    /// elle en sort sans attendre le prochain rafraîchissement.
    func testMarkingDoneRemovesTheTaskFromTheCache() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, "/v1/data_sources/ds-tasks/query", status: 200,
                                json: response([page("t-1", "Écrire"), page("t-2", "Relire")]))
        await transport.enqueue(.patch, "/v1/pages/t-1", status: 200,
                                json: #"{"object":"page","id":"t-1"}"#)
        // Le statut porte ici son groupe « terminé » : c'est lui qui rend la
        // valeur écrite, et sans lui rien ne pourrait être marqué.
        let cache = TaskCache(client: NotionClient(transport: transport,
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: mapping.merging([
                                .taskStatus: PropertyRef(id: "p-sta", name: "Status", type: "status",
                                                         options: ["En cours", "Terminé"],
                                                         completeOptions: ["Terminé"])
                              ]) { _, new in new }),
                              dataSourceID: "ds-tasks",
                              settings: TaskFilterSettings())
        try await cache.refresh()

        try await cache.markDone("t-1")

        let remaining = await cache.tasks.map(\.id)
        XCTAssertEqual(remaining, ["t-2"])
    }

    /// Sans valeur « terminé » exprimable, rien n'est écrit : mieux vaut le dire
    /// que d'inventer un libellé que la base refusera.
    func testMarkingDoneRefusesWhenTheSchemaSaysNothing() async throws {
        let transport = FixtureTransport()
        let cache = TaskCache(client: NotionClient(transport: transport,
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: [
                                .taskTitle: PropertyRef(id: "title", name: "Name", type: "title"),
                                .taskStatus: PropertyRef(id: "p-sta", name: "Statut", type: "select",
                                                         options: ["Ouvert", "Clos"])
                              ]),
                              dataSourceID: "ds-tasks",
                              settings: TaskFilterSettings())

        do {
            _ = try await cache.markDone("t-1")
            XCTFail("aucune valeur terminée : l'écriture ne devait pas partir")
        } catch let refusal as TaskCache.CompletionRefusal {
            XCTAssertEqual(refusal, .noDoneValue)
        }
        let count = await transport.requestCount(.patch, "/v1/pages/t-1")
        XCTAssertEqual(count, 0)
    }

    // MARK: - Création (US3)

    /// Une base range ses nouvelles tâches sous un statut par défaut : c'est
    /// celui-là que la ligne doit porter, et non « sans statut » jusqu'au
    /// prochain rafraîchissement. La réponse de création le contient déjà.
    func testCreatedTaskKeepsTheStatusNotionAssigned() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, "/v1/pages", status: 200,
                                json: page("t-9", "Écrire le rapport", status: "À faire"))
        let cache = makeCache(transport)

        let created = try await cache.createTask(titled: "Écrire le rapport")

        XCTAssertEqual(created.statusValue, "À faire")
        let cached = await cache.task("t-9")
        XCTAssertEqual(cached?.statusValue, "À faire")
    }

    // MARK: - Lire et écrire le statut (US3)

    /// Le schéma du magasin peut dater : les valeurs proposées viennent de la
    /// base telle qu'elle est aujourd'hui, avec son groupe « terminé ».
    func testStatusOptionsComeFromTheLiveSchema() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, "/v1/data_sources/ds-tasks", status: 200, json: #"""
        {"object":"data_source","id":"ds-tasks","title":[],"properties":{
          "Status":{"id":"p-sta","name":"Status","type":"status","status":{
            "options":[{"id":"o1","name":"À faire"},{"id":"o2","name":"En revue"},
                       {"id":"o3","name":"Livré"}],
            "groups":[{"id":"g1","name":"To-do","option_ids":["o1"]},
                      {"id":"g2","name":"In progress","option_ids":["o2"]},
                      {"id":"g3","name":"Complete","option_ids":["o3"]}]}}}}
        """#.replacingOccurrences(of: "\n", with: ""))
        let cache = makeCache(transport)

        let options = await cache.statusOptions()

        XCTAssertEqual(options.map(\.name), ["À faire", "En revue", "Livré"])
        XCTAssertEqual(options.filter(\.isComplete).map(\.name), ["Livré"])
    }

    /// Notion injoignable ne doit pas vider le menu : on retombe sur le schéma
    /// retenu à la liaison, qui reste vrai la plupart du temps.
    func testStatusOptionsFallBackToTheBoundSchema() async throws {
        let transport = FixtureTransport()
        let cache = TaskCache(client: NotionClient(transport: transport,
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: [
                                .taskStatus: PropertyRef(id: "p-sta", name: "Status", type: "status",
                                                         options: ["Ouvert", "Clos"],
                                                         completeOptions: ["Clos"])
                              ]),
                              dataSourceID: "ds-tasks",
                              settings: TaskFilterSettings())

        let options = await cache.statusOptions()

        XCTAssertEqual(options.map(\.name), ["Ouvert", "Clos"])
        XCTAssertEqual(options.filter(\.isComplete).map(\.name), ["Clos"])
    }

    /// Écrire un statut ordinaire garde la tâche, avec sa nouvelle valeur : la
    /// ligne se met à jour sans attendre le prochain rafraîchissement.
    func testWritingAStatusUpdatesTheCachedTask() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, "/v1/data_sources/ds-tasks/query", status: 200,
                                json: response([page("t-1", "Écrire")]))
        await transport.enqueue(.patch, "/v1/pages/t-1", status: 200,
                                json: #"{"object":"page","id":"t-1"}"#)
        let cache = makeCache(transport)
        try await cache.refresh()

        let completed = try await cache.setStatus("En revue", on: "t-1")

        XCTAssertFalse(completed)
        let updated = await cache.tasks.first
        XCTAssertEqual(updated?.statusValue, "En revue")
    }

    /// Un statut du groupe « terminé » sort la tâche de la liste sur-le-champ.
    func testWritingACompleteStatusRemovesTheTask() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, "/v1/data_sources/ds-tasks/query", status: 200,
                                json: response([page("t-1", "Écrire"), page("t-2", "Relire")]))
        await transport.enqueue(.patch, "/v1/pages/t-1", status: 200,
                                json: #"{"object":"page","id":"t-1"}"#)
        let cache = TaskCache(client: NotionClient(transport: transport,
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: mapping.merging([
                                .taskStatus: PropertyRef(id: "p-sta", name: "Status", type: "status",
                                                         options: ["En cours", "Terminé"],
                                                         completeOptions: ["Terminé"])
                              ]) { _, new in new }),
                              dataSourceID: "ds-tasks",
                              settings: TaskFilterSettings())
        try await cache.refresh()

        let completed = try await cache.setStatus("Terminé", on: "t-1")

        XCTAssertTrue(completed)
        let remaining = await cache.tasks.map(\.id)
        XCTAssertEqual(remaining, ["t-2"])
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
        settings.onlyAssignedToMe = true

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

    /// US3.2 — par défaut, aucune tâche n'est écartée sur le responsable.
    ///
    /// C'est le défaut qui compte : une base partagée porte des tâches sans
    /// responsable, et les écarter d'office donnait une liste amputée sans que
    /// rien ne le dise.
    func testAssigneeClauseIsAbsentUnlessAsked() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([]))
        var settings = TaskFilterSettings()
        settings.currentUserID = "u-1"

        try await makeCache(transport, settings: settings).refresh()

        let recorded = await transport.recorded
        let serialized = String(decoding: recorded[0].body ?? Data(), as: UTF8.self)
        XCTAssertFalse(serialized.contains("u-1"),
                       "aucune clause Personne tant qu'elle n'est pas demandée : \(serialized)")
    }

    /// Un identifiant d'utilisateur vide ne doit jamais devenir une clause :
    /// `people.contains("")` ne désigne personne, et faisait disparaître toutes
    /// les tâches assignées après une nouvelle connexion OAuth.
    func testEmptyUserIDNeverBecomesAClause() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([]))
        var settings = TaskFilterSettings()
        settings.currentUserID = ""
        settings.onlyAssignedToMe = true

        try await makeCache(transport, settings: settings).refresh()

        let recorded = await transport.recorded
        let serialized = String(decoding: recorded[0].body ?? Data(), as: UTF8.self)
        XCTAssertFalse(serialized.contains("contains"),
                       "clause Personne bâtie sur un identifiant vide : \(serialized)")
    }

    /// Une tâche sans statut n'est pas une tâche terminée : le filtre le dit
    /// explicitement plutôt que de s'en remettre à `does_not_equal`.
    func testTasksWithoutStatusAreNeverExcluded() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: response([]))
        var settings = TaskFilterSettings()
        settings.doneStatusValues = ["Terminé"]

        try await makeCache(transport, settings: settings).refresh()

        let recorded = await transport.recorded
        let serialized = String(decoding: recorded[0].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(serialized.contains("is_empty"), "obtenu : \(serialized)")
    }

    /// Un filtre refusé par Notion ne doit jamais se solder par une liste vide :
    /// on relit sans filtre, et l'on écarte les tâches terminées ici.
    func testARejectedFilterFallsBackToAnUnfilteredRead() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.queryDataSource("ds-tasks")
        await transport.enqueue(.post, path, status: 400,
                                json: #"{"object":"error","status":400,"code":"validation_error","message":"propriété inconnue"}"#)
        await transport.enqueue(.post, path, status: 200,
                                json: response([page("t-1", "Ouverte", status: "En cours"),
                                                page("t-2", "Close", status: "Terminé")]))

        var settings = TaskFilterSettings()
        settings.doneStatusValues = ["Terminé"]
        let cache = makeCache(transport, settings: settings)
        try await cache.refresh()

        let tasks = await cache.tasks
        XCTAssertEqual(tasks.map(\.title), ["Ouverte"],
                       "la liste doit survivre au refus, sans la tâche terminée")
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
