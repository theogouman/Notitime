import XCTest
@testable import NotitimeCore

/// Le vocabulaire écrit ou filtré vient **du schéma**, jamais du code.
///
/// Les trois fixtures sont relevées sur un workspace réel (27 août 2026) : elles
/// portent les options et les groupes tels que Notion les renvoie, pas seulement
/// les noms et les types. C'est ce qui manquait aux fixtures précédentes — un
/// filtre sur « Done » ou une méthode « Tracker » y passaient sans bruit.
final class RealSchemaTests: XCTestCase {

    private func source(_ name: String) throws -> NotionDataSource {
        try Fixture.decode(NotionDataSource.self, "data_source_published_template_\(name)")
    }

    private func mapping(_ name: String, as role: DatabaseRole) throws -> [PropertyKey: PropertyRef] {
        let validation = SchemaValidator().validate(try source(name), as: role)
        XCTAssertTrue(validation.isValid, "la source réelle doit valider pour \(role)")
        return validation.propertyMap
    }

    /// Toutes les valeurs de `select`/`status` réellement déclarées par la source.
    private func declaredOptions(_ dataSource: NotionDataSource, _ property: String) -> [String] {
        dataSource.properties[property]?.options ?? []
    }

    // MARK: - Filtre des tâches (FR-011)

    /// Le filtre ne doit nommer que des options existantes : Notion rejette la
    /// requête entière dès qu'une valeur lui est inconnue, et le chargement des
    /// tâches échoue en bloc.
    func testTaskFilterOnlyNamesOptionsThatExist() async throws {
        let tasks = try source("tasks")
        let cache = TaskCache(client: NotionClient(transport: FixtureTransport(),
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: try mapping("tasks", as: .tasks)),
                              dataSourceID: "ds-tpl-tasks",
                              settings: AppSettings().taskFilterSettings(currentUserID: nil))

        let filter = await cache.queryFilter()
        let named = RealSchemaTests.statusValues(in: filter)
        let declared = Set(declaredOptions(tasks, "Status"))

        XCTAssertFalse(named.isEmpty, "le filtre doit exclure les tâches terminées")
        for value in named {
            XCTAssertTrue(declared.contains(value),
                          "« \(value) » n'existe pas dans la base : \(declared.sorted())")
        }
    }

    /// Ce sont les options du groupe « terminé » qui font foi, pas une liste
    /// écrite dans le code : ici « Terminé » **et** « Annulé ».
    func testTaskFilterExcludesTheCompleteGroup() async throws {
        let cache = TaskCache(client: NotionClient(transport: FixtureTransport(),
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: try mapping("tasks", as: .tasks)),
                              dataSourceID: "ds-tpl-tasks",
                              settings: AppSettings().taskFilterSettings(currentUserID: nil))

        let named = RealSchemaTests.statusValues(in: await cache.queryFilter())

        XCTAssertEqual(named, ["Terminé", "Annulé"])
    }

    /// FR-011, US3.2 — le filtre Personne ne doit écarter que les tâches
    /// confiées à quelqu'un d'autre.
    ///
    /// L'identifiant employé est celui du **propriétaire du compte**, pas celui
    /// du bot : filtrer sur le bot ne remonterait jamais une tâche assignée.
    func testTheAssigneeClauseKeepsMineAndTheUnassignedOnes() async throws {
        var settings = AppSettings().taskFilterSettings(currentUserID: "user-théo")
        settings.includeUnassigned = true
        let cache = TaskCache(client: NotionClient(transport: FixtureTransport(),
                                                   authorization: StaticAuthorization(),
                                                   rateLimiter: .forTesting(VirtualTimeSource())),
                              mapper: PropertyMapper(map: try mapping("tasks", as: .tasks)),
                              dataSourceID: "ds-tpl-tasks",
                              settings: settings)

        let built = await cache.queryFilter()
        let filter = try XCTUnwrap(built)
        let clauses = try XCTUnwrap(filter["and"] as? [[String: Any]])
        let either = try XCTUnwrap(clauses.compactMap { $0["or"] as? [[String: Any]] }.first)

        XCTAssertEqual(either.count, 2)
        XCTAssertEqual((either[0]["people"] as? [String: Any])?["contains"] as? String, "user-théo")
        XCTAssertEqual((either[1]["people"] as? [String: Any])?["is_empty"] as? Bool, true)
        // Le statut reste filtré en même temps : les deux clauses coexistent.
        XCTAssertEqual(RealSchemaTests.statusValues(in: filter), ["Terminé", "Annulé"])
    }

    // MARK: - Écriture d'une entrée (FR-026)

    /// Aucune valeur inventée : chaque `select` et chaque `status` écrit doit
    /// figurer dans le schéma de Time Tracker. « Tracker » n'y figure pas —
    /// l'option s'appelle « Time Tracker ».
    func testEntryNeverWritesAnOptionThatDoesNotExist() throws {
        let timeTracker = try source("time_tracker")
        let mapper = PropertyMapper(map: try mapping("time_tracker", as: .timeEntries))
        let composer = EntryComposer(mapper: mapper, dataSourceID: "ds-tpl-time-tracker",
                                     personUserID: "u-1", taskTitleLookup: { _ in "Tâche" })

        for mode in [SessionMode.pomodoro, .tracker] {
            for outcome in [SessionOutcome.ranToTerm, .shortened] {
                let body = composer.pageBody(for: entry(mode: mode, outcome: outcome))
                let properties = body["properties"] as? [String: Any] ?? [:]

                for (name, raw) in properties {
                    guard let value = raw as? [String: Any] else { continue }
                    for container in ["select", "status"] {
                        guard let holder = value[container] as? [String: Any],
                              let written = holder["name"] as? String else { continue }
                        XCTAssertTrue(declaredOptions(timeTracker, name).contains(written),
                                      "\(mode)/\(outcome) : « \(written) » absent de « \(name) » "
                                      + "— options : \(declaredOptions(timeTracker, name))")
                    }
                }
            }
        }
    }

    // MARK: - Vérification d'idempotence (FR-028)

    /// `in_trash` n'est pas un paramètre d'interrogation : Notion rejette le
    /// corps entier, la vérification échoue, et l'entrée ne part jamais.
    /// `is_archived` est le seul sélecteur accepté — c'est ce que dit le contrat.
    func testIdempotencyQueryUsesIsArchivedNotInTrash() throws {
        let composer = EntryComposer(mapper: PropertyMapper(map: try mapping("time_tracker", as: .timeEntries)),
                                     dataSourceID: "ds-tpl-time-tracker",
                                     personUserID: "u-1", taskTitleLookup: { _ in "Tâche" })
        let entry = entry(mode: .pomodoro, outcome: .ranToTerm)

        let plain = composer.idempotencyQuery(for: entry, includeArchived: false)
        let archived = composer.idempotencyQuery(for: entry, includeArchived: true)

        XCTAssertNil(plain["in_trash"], "in_trash n'est jamais accepté en corps de requête")
        XCTAssertNil(archived["in_trash"], "in_trash n'est jamais accepté en corps de requête")
        XCTAssertNil(plain["is_archived"], "par défaut : les pages non archivées")
        XCTAssertEqual(archived["is_archived"] as? Bool, true)
    }

    // MARK: - Indépendance au nom des groupes

    /// Le nom des groupes est renommable dans l'interface Notion et n'est pas
    /// traduit de façon prévisible : la reconnaissance ne peut pas en dépendre
    /// seule. Notion impose exactement trois groupes, dans l'ordre à faire, en
    /// cours, terminé — la position tranche quand le nom ne dit rien.
    func testCompleteGroupIsFoundWhateverItIsCalled() throws {
        for groupNames in [["To-do", "In progress", "Complete"],
                           ["À faire", "En cours", "Terminé"],
                           ["Alpha", "Beta", "Gamma"]] {
            let schema = try decodeStatus(groupNames: groupNames)
            XCTAssertEqual(schema.completeOptions, ["Livré", "Abandonné"],
                           "groupes nommés \(groupNames)")
        }
    }

    /// Un `select` n'a pas de groupes : rien n'est déduit, et c'est au réglage
    /// de l'utilisateur de dire ce qui compte comme terminé.
    func testSelectHasNoCompleteGroupAndReliesOnTheSetting() throws {
        let reference = PropertyRef(id: "p", name: "Statut", type: "select",
                                    options: ["Ouvert", "Clos"], completeOptions: [])

        XCTAssertEqual(TaskCache.doneValues(for: reference, adding: []), [])
        XCTAssertEqual(TaskCache.doneValues(for: reference, adding: ["Clos"]), ["Clos"])
        XCTAssertEqual(TaskCache.doneValues(for: reference, adding: ["Fermé"]), [],
                       "une valeur inconnue de la base est écartée, jamais envoyée")
    }

    private func decodeStatus(groupNames: [String]) throws -> NotionPropertySchema {
        let json = """
        {"id":"p-sta","name":"Status","type":"status","status":{
          "options":[{"id":"o1","name":"À faire","color":"gray"},
                     {"id":"o2","name":"En cours","color":"blue"},
                     {"id":"o3","name":"Livré","color":"green"},
                     {"id":"o4","name":"Abandonné","color":"red"}],
          "groups":[{"id":"g1","name":"\(groupNames[0])","color":"gray","option_ids":["o1"]},
                    {"id":"g2","name":"\(groupNames[1])","color":"blue","option_ids":["o2"]},
                    {"id":"g3","name":"\(groupNames[2])","color":"green","option_ids":["o3","o4"]}]}}
        """
        return try JSONDecoder().decode(NotionPropertySchema.self, from: Data(json.utf8))
    }

    // MARK: - Support

    private func entry(mode: SessionMode, outcome: SessionOutcome) -> ComposedEntry {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        return ComposedEntry(localID: UUID(), taskPageID: "t-1", title: "T",
                             startedAt: start, endedAt: start.addingTimeInterval(1500),
                             durationMinutes: 25, mode: mode, outcome: outcome,
                             shortenReason: outcome == .shortened ? .user : nil,
                             subtractedIdleMinutes: 0)
    }

    /// Extrait les valeurs de statut nommées par un filtre, quelle que soit sa
    /// forme — clause seule ou `and` de clauses.
    static func statusValues(in filter: [String: Any]?) -> [String] {
        guard let filter else { return [] }
        if let clauses = filter["and"] as? [[String: Any]] {
            return clauses.flatMap { statusValues(in: $0) }
        }
        if let clauses = filter["or"] as? [[String: Any]] {
            return clauses.flatMap { statusValues(in: $0) }
        }
        for container in ["status", "select"] {
            if let holder = filter[container] as? [String: Any] {
                return holder.values.compactMap { $0 as? String }
            }
        }
        return []
    }
}
