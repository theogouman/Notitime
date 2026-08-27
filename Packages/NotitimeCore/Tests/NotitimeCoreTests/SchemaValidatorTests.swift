import XCTest
@testable import NotitimeCore

/// FR-006 : validation du schéma d'une source assignée, liste des propriétés
/// manquantes, et proposition de création de celles que l'app sait créer.
final class SchemaValidatorTests: XCTestCase {

    private let validator = SchemaValidator()

    func testValidTimeEntriesSourceMapsEveryRequiredProperty() throws {
        let source = try Fixture.decode(NotionDataSource.self, "data_source_time_entries_valid")
        let result = validator.validate(source, as: .timeEntries)

        XCTAssertTrue(result.isValid)
        let map = result.propertyMap
        XCTAssertEqual(map[.entryTitle]?.id, "title")
        XCTAssertEqual(map[.entryTask]?.id, "p-task")
        XCTAssertEqual(map[.entryStart]?.id, "p-str")
        XCTAssertEqual(map[.entryEnd]?.id, "p-end")
        XCTAssertEqual(map[.entryDuration]?.id, "p-dur")
        XCTAssertEqual(map[.entryType]?.id, "p-typ")
        XCTAssertEqual(map[.entryStatus]?.id, "p-sta")
        XCTAssertEqual(map[.entryPerson]?.id, "p-per")
        XCTAssertEqual(map[.entryLocalID]?.id, "p-lid")
        XCTAssertEqual(map[.entryLocalID]?.name, "ID")
        XCTAssertEqual(map[.entryLocalID]?.type, "rich_text")
    }

    func testTwoDatePropertiesAreNotConfused() throws {
        let source = try Fixture.decode(NotionDataSource.self, "data_source_time_entries_valid")
        let map = validator.validate(source, as: .timeEntries).propertyMap
        // Début et Fin sont toutes deux de type date : c'est le nom qui départage,
        // et aucune propriété ne doit être consommée deux fois.
        XCTAssertNotEqual(map[.entryStart]?.id, map[.entryEnd]?.id)
        XCTAssertNotEqual(map[.entryType]?.id, map[.entryStatus]?.id)
    }

    func testUniqueIDPropertyDoesNotSatisfyTheIdempotencyRequirement() throws {
        let source = try Fixture.decode(NotionDataSource.self, "data_source_time_entries_missing_id")
        let result = validator.validate(source, as: .timeEntries)

        // Un `unique_id` Notion n'a de valeur qu'après création de la page : il ne
        // peut pas servir de clé de déduplication écrite avant l'envoi (FR-028).
        guard case .missing(let missing, let creatable, _) = result else {
            return XCTFail("la source devrait être refusée, résultat : \(result)")
        }
        XCTAssertEqual(missing, [.entryLocalID])
        XCTAssertEqual(creatable, [.entryLocalID], "l'app sait créer une propriété rich text")
    }

    func testCreationPayloadForMissingLocalID() {
        let payload = validator.creationPayload(for: [.entryLocalID], role: .timeEntries)
        XCTAssertNotNil(payload["ID"], "la propriété créée porte le nom par défaut « ID »")
        XCTAssertNotNil((payload["ID"] as? [String: Any])?["rich_text"])
    }

    func testCreationPayloadCarriesSelectOptions() {
        let payload = validator.creationPayload(for: [.entryStatus, .entryType], role: .timeEntries)
        let statut = (payload["Statut"] as? [String: Any])?["select"] as? [String: Any]
        let options = (statut?["options"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(options, ["Complété", "Écourté"])

        let type = (payload["Type"] as? [String: Any])?["select"] as? [String: Any]
        let typeOptions = (type?["options"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(typeOptions, ["Pomodoro", "Tracker"])
    }

    func testTasksAcceptsStatusOrSelectAndIgnoresRollups() throws {
        let source = try Fixture.decode(NotionDataSource.self, "data_source_tasks_valid")
        let result = validator.validate(source, as: .tasks)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.propertyMap[.taskStatus]?.type, "status")
        XCTAssertEqual(result.propertyMap[.taskAssignee]?.id, "t-per")
        XCTAssertEqual(result.propertyMap[.taskProject]?.id, "t-prj")
        // Les rollups du template ne sont ni lus ni mappés.
        XCTAssertFalse(result.propertyMap.values.contains { $0.type == "rollup" })
    }

    func testRenamedPropertiesStillValidateBecauseMatchingIsByType() throws {
        let source = try Fixture.decode(NotionDataSource.self, "data_source_tasks_renamed")
        let result = validator.validate(source, as: .tasks)

        // « Intitulé » et « Avancement » : aucun nom par défaut ne correspond, mais
        // le type est unique et sans ambiguïté. C'est le cas limite « template
        // modifié par l'équipe » de la spec.
        XCTAssertTrue(result.isValid, "un renommage ne doit pas casser la validation")
        XCTAssertEqual(result.propertyMap[.taskTitle]?.name, "Intitulé")
        XCTAssertEqual(result.propertyMap[.taskStatus]?.name, "Avancement")
    }

    func testOptionalPropertiesAreNotRequired() throws {
        let source = try Fixture.decode(NotionDataSource.self, "data_source_tasks_renamed")
        let result = validator.validate(source, as: .tasks)
        // Personne et Projet sont optionnels (FR-011, FR-012) : leur absence ne
        // doit pas invalider la configuration.
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.propertyMap[.taskAssignee])
        XCTAssertNil(result.propertyMap[.taskProject])
    }

    func testExistingMappingIsHonouredEvenAfterRename() throws {
        let source = try Fixture.decode(NotionDataSource.self, "data_source_tasks_valid")
        // L'utilisateur avait mappé Statut ; la propriété a été renommée depuis.
        // L'id étant stable, le mapping mémorisé doit continuer de valoir.
        let pinned: [PropertyKey: PropertyRef] = [
            .taskStatus: PropertyRef(id: "t-sta", name: "AncienNom", type: "status")
        ]
        let result = validator.validate(source, as: .tasks, existingMap: pinned)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.propertyMap[.taskStatus]?.id, "t-sta")
        XCTAssertEqual(result.propertyMap[.taskStatus]?.name, "Statut", "le nom affiché est rafraîchi")
    }
}
