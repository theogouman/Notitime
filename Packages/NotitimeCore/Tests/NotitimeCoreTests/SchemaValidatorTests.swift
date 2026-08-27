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

/// Confrontation du schéma attendu au template Notion **réellement publié**.
///
/// Ces tests sont nés du diagnostic de l'écran « assignés[] ambigus[projects×3] »
/// observé en production : le validateur ne reconnaissait ni Time Entries ni
/// Tâches — leurs noms de propriétés ne sont pas ceux de la documentation — et
/// les trois sources se rabattaient sur le seul rôle Projets, qui n'exige qu'un
/// titre. Ils verrouillent désormais la reconnaissance du template tel qu'il est
/// diffusé, noms réels compris.
final class PublishedTemplateSchemaTests: XCTestCase {

    private func map(_ fixture: String, as role: DatabaseRole) throws -> [PropertyKey: PropertyRef] {
        let source = try Fixture.decode(NotionDataSource.self, fixture)
        let validation = SchemaValidator().validate(source, as: role)
        guard case .valid(let map) = validation else {
            throw XCTSkip("attendu valide, obtenu : \(validation)")
        }
        return map
    }

    /// Les neuf propriétés, sous leurs noms réels — dont « Status » en type
    /// `status` (et non `select`) et deux dates que seul leur libellé distingue.
    func testPublishedTimeTrackerIsRecognised() throws {
        let map = try map("data_source_published_template_time_tracker", as: .timeEntries)

        XCTAssertEqual(map[.entryTitle]?.name, "Name")
        XCTAssertEqual(map[.entryTask]?.name, "Tâches")
        XCTAssertEqual(map[.entryStart]?.name, "Date de début")
        XCTAssertEqual(map[.entryEnd]?.name, "Date de fin")
        XCTAssertEqual(map[.entryDuration]?.name, "Durée en min")
        XCTAssertEqual(map[.entryType]?.name, "Méthode")
        XCTAssertEqual(map[.entryStatus]?.name, "Status")
        XCTAssertEqual(map[.entryStatus]?.type, "status", "le type `status` est accepté")
        XCTAssertEqual(map[.entryPerson]?.name, "Responsable")
        XCTAssertEqual(map[.entryLocalID]?.name, "ID")
    }

    /// Le piège de cette base : « Status » (status) et « Type » (select) sont
    /// tous deux éligibles au statut. Le fragment de nom tranche.
    func testPublishedTasksIsRecognised() throws {
        let map = try map("data_source_published_template_tasks", as: .tasks)

        XCTAssertEqual(map[.taskTitle]?.name, "Name")
        XCTAssertEqual(map[.taskStatus]?.name, "Status")
        XCTAssertEqual(map[.taskAssignee]?.name, "Responsable")
        XCTAssertEqual(map[.taskProject]?.name, "Projets",
                       "« Projets » l'emporte sur « Time Tracker », deux relations")
    }

    /// Début et fin ne doivent jamais être interverties : une entrée finissant
    /// avant de commencer produirait une durée négative dans Notion.
    func testStartAndEndAreNotSwapped() throws {
        let map = try map("data_source_published_template_time_tracker", as: .timeEntries)

        XCTAssertNotEqual(map[.entryStart]?.id, map[.entryEnd]?.id)
        XCTAssertEqual(map[.entryStart]?.id, "p-str")
        XCTAssertEqual(map[.entryEnd]?.id, "p-end")
    }

    /// Ces sources satisfont aussi le rôle Projets, qui n'exige qu'un titre :
    /// c'est l'ordre « rôle le plus contraint d'abord » qui évite qu'elles le
    /// raflent, pas la validation.
    func testEveryPublishedSourceStillSatisfiesProjects() throws {
        for name in ["data_source_published_template_time_tracker",
                     "data_source_published_template_tasks"] {
            let source = try Fixture.decode(NotionDataSource.self, name)
            XCTAssertTrue(SchemaValidator().validate(source, as: .projects).isValid, name)
        }
    }
}
