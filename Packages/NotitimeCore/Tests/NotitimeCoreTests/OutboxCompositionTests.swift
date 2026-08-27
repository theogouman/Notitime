import XCTest
@testable import NotitimeCore

/// T048 — composition d'une entrée de temps à partir d'une session éligible.
///
/// Le corps envoyé à Notion est vérifié champ par champ : c'est la seule chose
/// que l'utilisateur verra dans sa base, et une erreur y est silencieuse.
final class OutboxCompositionTests: XCTestCase {

    /// Construite depuis sa représentation ISO pour que l'instant attendu soit
    /// lisible dans le test plutôt que calculé de tête.
    private let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
    private let taskPage = "task-page-1"

    /// Mapping du template diffusé, noms réels compris.
    private func mapper(entryStatusType: String = "status") -> PropertyMapper {
        PropertyMapper(map: [
            .entryTitle: PropertyRef(id: "title", name: "Name", type: "title"),
            .entryTask: PropertyRef(id: "p-task", name: "Tâches", type: "relation"),
            .entryStart: PropertyRef(id: "p-str", name: "Date de début", type: "date"),
            .entryEnd: PropertyRef(id: "p-end", name: "Date de fin", type: "date"),
            .entryDuration: PropertyRef(id: "p-dur", name: "Durée en min", type: "number"),
            .entryType: PropertyRef(id: "p-met", name: "Méthode", type: "select"),
            .entryStatus: PropertyRef(id: "p-sta", name: "Status", type: entryStatusType),
            .entryPerson: PropertyRef(id: "p-per", name: "Responsable", type: "people"),
            .entryLocalID: PropertyRef(id: "p-lid", name: "ID", type: "rich_text")
        ])
    }

    private func session(outcome: SessionOutcome = .ranToTerm,
                         seconds: Int = 1500,
                         mode: SessionMode = .pomodoro,
                         shortenReason: ShortenReason? = nil,
                         subtractedIdleSeconds: Int = 0) -> CompletedSession {
        CompletedSession(localID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                         taskPageID: taskPage,
                         mode: mode,
                         startedAt: start,
                         endedAt: start.addingTimeInterval(TimeInterval(seconds)),
                         effectiveSeconds: seconds,
                         outcome: outcome,
                         shortenReason: shortenReason,
                         subtractedIdleSeconds: subtractedIdleSeconds)
    }

    private func composer() -> EntryComposer {
        EntryComposer(mapper: mapper(),
                      dataSourceID: "ds-time-entries",
                      personUserID: "user-1",
                      taskTitleLookup: { _ in "Refonte facturation" })
    }

    // MARK: - Les neuf propriétés de FR-026

    func testEveryRequiredPropertyIsPresent() throws {
        let entry = composer().compose(session())
        let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])

        XCTAssertEqual(Set(properties.keys),
                       ["Name", "Tâches", "Date de début", "Date de fin",
                        "Durée en min", "Méthode", "Status", "Responsable", "ID"])
    }

    func testDurationIsWholeMinutes() {
        XCTAssertEqual(composer().compose(session(seconds: 1500)).durationMinutes, 25)
        XCTAssertEqual(composer().compose(session(seconds: 90)).durationMinutes, 2,
                       "90 s s'arrondit à la minute la plus proche")
        XCTAssertEqual(composer().compose(session(seconds: 60)).durationMinutes, 1)
    }

    /// La relation ne porte que l'identifiant de page de la tâche.
    func testTaskRelationCarriesOnlyThePageID() throws {
        let entry = composer().compose(session())
        let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])
        let relation = try XCTUnwrap(properties["Tâches"] as? [String: Any])
        let items = try XCTUnwrap(relation["relation"] as? [[String: Any]])

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["id"] as? String, taskPage)
    }

    /// R-01 — la page se crée dans une **source**, pas dans une base.
    func testParentIsTheDataSource() throws {
        let body = composer().pageBody(for: composer().compose(session()))
        let parent = try XCTUnwrap(body["parent"] as? [String: Any])

        XCTAssertEqual(parent["data_source_id"] as? String, "ds-time-entries")
        XCTAssertNil(parent["database_id"], "un database_id créerait la page au mauvais endroit")
    }

    func testDatesAreSentInUTC() throws {
        let entry = composer().compose(session())
        let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])
        let begin = try XCTUnwrap(properties["Date de début"] as? [String: Any])
        let date = try XCTUnwrap(begin["date"] as? [String: Any])

        XCTAssertEqual(date["start"] as? String, "2026-08-27T14:30:00Z")
    }

    func testLocalIdentifierIsWrittenAsRichText() throws {
        let entry = composer().compose(session())
        let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])
        let identifier = try XCTUnwrap(properties["ID"] as? [String: Any])
        let items = try XCTUnwrap(identifier["rich_text"] as? [[String: Any]])
        let content = (items.first?["text"] as? [String: Any])?["content"] as? String

        XCTAssertEqual(content, entry.localID.uuidString)
    }

    func testPersonIsTheCurrentUser() throws {
        let entry = composer().compose(session())
        let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])
        let people = try XCTUnwrap(properties["Responsable"] as? [String: Any])
        let items = try XCTUnwrap(people["people"] as? [[String: Any]])

        XCTAssertEqual(items.first?["id"] as? String, "user-1")
    }

    // MARK: - Titre généré (data-model §3)

    func testGeneratedTitleFollowsTheDocumentedFormat() {
        let entry = composer().compose(session(seconds: 1500))

        XCTAssertTrue(entry.title.hasPrefix("Refonte facturation — 25 min — "),
                      "obtenu : \(entry.title)")
    }

    /// La troncature porte sur le titre de la tâche, jamais sur la durée ni la
    /// date — ce sont elles qui distinguent deux sessions du même jour.
    func testLongTaskTitleIsTruncatedWithoutLosingDurationOrDate() {
        let composer = EntryComposer(mapper: mapper(), dataSourceID: "ds",
                                     personUserID: "user-1",
                                     taskTitleLookup: { _ in String(repeating: "é", count: 400) })

        let entry = composer.compose(session(seconds: 1500))

        XCTAssertLessThanOrEqual(entry.title.count, 200)
        XCTAssertTrue(entry.title.contains("25 min"))
    }

    // MARK: - Statut et méthode, face aux options réelles du template

    /// Le template diffusé porte un `status` dont les options sont « Terminée »
    /// et « Interrompue ». L'API Notion **ne crée pas** d'option de `status` à la
    /// volée : écrire « Complété » y échouerait en 400. Le résultat de session se
    /// projette donc sur les options réellement présentes.
    func testOutcomeMapsOntoTheExistingStatusOptions() throws {
        let options = ["À lancer", "En cours", "Terminée", "Interrompue"]
        let composer = EntryComposer(mapper: mapper(), dataSourceID: "ds",
                                     personUserID: "user-1",
                                     statusOptions: options,
                                     taskTitleLookup: { _ in "T" })

        let done = try XCTUnwrap(statusName(composer, outcome: .ranToTerm))
        let cut = try XCTUnwrap(statusName(composer, outcome: .shortened))

        XCTAssertEqual(done, "Terminée")
        XCTAssertEqual(cut, "Interrompue")
    }

    /// Sans option connue — cas d'un `select`, où Notion crée l'option — les
    /// valeurs canoniques de la spec sont écrites telles quelles.
    func testOutcomeFallsBackToTheCanonicalValues() throws {
        let composer = EntryComposer(mapper: mapper(entryStatusType: "select"),
                                     dataSourceID: "ds", personUserID: "user-1",
                                     statusOptions: [], taskTitleLookup: { _ in "T" })

        XCTAssertEqual(statusName(composer, outcome: .ranToTerm), "Complété")
        XCTAssertEqual(statusName(composer, outcome: .shortened), "Écourté")
    }

    /// Une propriété de type `status` s'écrit `{"status": …}` ; la traiter comme
    /// un `select` produirait un 400 de validation.
    func testStatusPropertyIsWrittenWithTheStatusContainer() throws {
        let entry = composer().compose(session())
        let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])
        let status = try XCTUnwrap(properties["Status"] as? [String: Any])

        XCTAssertNotNil(status["status"], "type `status` → conteneur `status`")
        XCTAssertNil(status["select"])
    }

    func testMethodCarriesTheSessionMode() throws {
        for (mode, expected) in [(SessionMode.pomodoro, "Pomodoro"), (.tracker, "Tracker")] {
            let entry = composer().compose(session(mode: mode))
            let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])
            let method = try XCTUnwrap(properties["Méthode"] as? [String: Any])
            let select = try XCTUnwrap(method["select"] as? [String: Any])
            XCTAssertEqual(select["name"] as? String, expected)
        }
    }

    // MARK: - Le motif d'écourtement ne fuit pas dans les propriétés

    /// FR-026a — `shortenReason` n'appartient qu'au commentaire.
    func testShortenReasonNeverAppearsInProperties() throws {
        let entry = composer().compose(session(outcome: .shortened, seconds: 300,
                                               shortenReason: .user))
        let properties = try XCTUnwrap(composer().pageBody(for: entry)["properties"] as? [String: Any])
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: properties),
                                as: UTF8.self)

        // Chercher la valeur brute « user » donnerait un faux positif : la
        // propriété Responsable contient légitimement {"object":"user"}. Deux
        // vérifications suffisent : le motif ne peut fuir que sous forme de
        // libellé, ou sous forme de propriété supplémentaire.
        XCTAssertFalse(serialized.contains("utilisateur"), "le motif reste local")
        XCTAssertFalse(serialized.contains("écourt"))
        XCTAssertEqual(properties.count, 9, "exactement les neuf propriétés de FR-026")
        XCTAssertNil(properties["Motif"] ?? properties["Raison"])
    }

    /// FR-026a — pas de commentaire pour une session allée à son terme sans
    /// retranchement : il n'y aurait rien à y dire.
    func testNoCommentForACleanCompletedSession() {
        XCTAssertNil(composer().comment(for: composer().compose(session())))
    }

    func testCommentDescribesTheShorteningReason() throws {
        let entry = composer().compose(session(outcome: .shortened, seconds: 300,
                                               shortenReason: .user))
        let comment = try XCTUnwrap(composer().comment(for: entry))

        XCTAssertTrue(comment.contains("utilisateur"), "obtenu : \(comment)")
    }

    private func statusName(_ composer: EntryComposer, outcome: SessionOutcome) -> String? {
        let entry = composer.compose(session(outcome: outcome))
        guard let properties = composer.pageBody(for: entry)["properties"] as? [String: Any],
              let status = properties["Status"] as? [String: Any] else { return nil }
        for container in ["status", "select"] {
            if let object = status[container] as? [String: Any] { return object["name"] as? String }
        }
        return nil
    }
}
