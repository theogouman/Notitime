import XCTest
@testable import NotitimeCore

/// Les entrées de temps naissent du **modèle de page par défaut** de la base,
/// quand elle en a un.
///
/// Sans lui, la page créée par l'API est nue : elle porte les propriétés mais
/// aucun contenu, alors que le modèle défini dans Notion en prévoit. Le modèle
/// ne s'applique que si la base en déclare un par défaut — le demander sans
/// qu'il existe fait refuser la création, et l'entrée resterait en file.
final class PageTemplateTests: XCTestCase {

    private let mapping: [PropertyKey: PropertyRef] = [
        .entryTitle: PropertyRef(id: "title", name: "Name", type: "title"),
        .entryLocalID: PropertyRef(id: "p-lid", name: "ID", type: "rich_text")
    ]

    private func composer(usesDefaultTemplate: Bool) -> EntryComposer {
        EntryComposer(mapper: PropertyMapper(map: mapping), dataSourceID: "ds-te",
                      personUserID: "u-1", usesDefaultTemplate: usesDefaultTemplate,
                      taskTitleLookup: { _ in "Tâche" })
    }

    private func entry() -> ComposedEntry {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        return ComposedEntry(localID: UUID(), taskPageID: "t-1", title: "T",
                             startedAt: start, endedAt: start.addingTimeInterval(1500),
                             durationMinutes: 25, mode: .pomodoro, outcome: .ranToTerm,
                             shortenReason: nil, subtractedIdleMinutes: 0)
    }

    // MARK: - Corps de création

    func testDefaultTemplateIsRequestedWhenTheSourceHasOne() throws {
        let body = composer(usesDefaultTemplate: true).pageBody(for: entry())

        let template = try XCTUnwrap(body["template"] as? [String: Any])
        XCTAssertEqual(template["type"] as? String, "default")
    }

    func testNoTemplateIsRequestedWhenTheSourceHasNone() {
        XCTAssertNil(composer(usesDefaultTemplate: false).pageBody(for: entry())["template"],
                     "demander un modèle inexistant ferait refuser la création")
    }

    /// L'API refuse `children` en même temps qu'un modèle. Les propriétés, elles,
    /// restent nécessaires : c'est le modèle qui fournit le contenu, pas les
    /// valeurs.
    func testTemplateDoesNotDisplaceThePropertiesAndSendsNoChildren() throws {
        let body = composer(usesDefaultTemplate: true).pageBody(for: entry())

        XCTAssertNil(body["children"], "l'API refuse children avec un modèle")
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertNotNil(properties["Name"])
        XCTAssertNotNil(properties["ID"])
    }

    // MARK: - Découverte du modèle par défaut

    /// Les charges de cette section sont celles que **publie la référence de
    /// l'API** : `{ templates, has_more, next_cursor }`. Cet endpoint ne suit pas
    /// l'enveloppe de liste habituelle — pas de `object`, pas de `results`. Ces
    /// trois tests l'avaient d'abord supposée, et affirmaient donc le contraire
    /// de ce que Notion répond : ils passaient pendant que la lecture échouait
    /// en production, et l'échec passait pour une base sans modèle.

    /// `GET /v1/data_sources/{id}/templates` — c'est `is_default` qui désigne le
    /// modèle appliqué par `template[type]=default`.
    func testDefaultTemplateIsDetectedFromTheSource() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, NotionAPI.Path.dataSourceTemplates("ds-te") + "?page_size=100",
                                status: 200,
                                json: #"""
                                {"templates":[
                                  {"id":"tpl-1","name":"Autre modèle","is_default":false},
                                  {"id":"tpl-2","name":"New Generic Task","is_default":true}],
                                 "has_more":false,"next_cursor":null}
                                """#)
        let client = NotionClient(transport: transport, authorization: StaticAuthorization(),
                                  rateLimiter: .forTesting(VirtualTimeSource()))

        let templates = try await client.dataSourceTemplates(id: "ds-te")

        XCTAssertEqual(templates.count, 2)
        XCTAssertEqual(templates.first(where: \.isDefault)?.id, "tpl-2")
    }

    /// Une base sans modèle par défaut se reconnaît à l'absence de `is_default` :
    /// on ne demandera pas de modèle pour elle.
    func testASourceWithoutADefaultTemplateIsRecognised() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.get, NotionAPI.Path.dataSourceTemplates("ds-te") + "?page_size=100",
                                status: 200,
                                json: #"{"templates":[{"id":"tpl-1","name":"M","is_default":false}],"has_more":false}"#)
        let client = NotionClient(transport: transport, authorization: StaticAuthorization(),
                                  rateLimiter: .forTesting(VirtualTimeSource()))

        let hasDefault = try await client.hasDefaultTemplate(dataSourceID: "ds-te")

        XCTAssertFalse(hasDefault)
    }

    /// La liste est paginée comme le reste de l'API : le modèle par défaut peut
    /// se trouver sur la seconde page.
    func testTemplateListIsPaginated() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.dataSourceTemplates("ds-te")
        await transport.enqueue(.get, path + "?page_size=100", status: 200,
                                json: #"{"templates":[{"id":"t1","name":"A","is_default":false}],"has_more":true,"next_cursor":"c1"}"#)
        await transport.enqueue(.get, path + "?page_size=100&start_cursor=c1", status: 200,
                                json: #"{"templates":[{"id":"t2","name":"B","is_default":true}],"has_more":false}"#)
        let client = NotionClient(transport: transport, authorization: StaticAuthorization(),
                                  rateLimiter: .forTesting(VirtualTimeSource()))

        let hasDefault = try await client.hasDefaultTemplate(dataSourceID: "ds-te")

        XCTAssertTrue(hasDefault, "le modèle par défaut était sur la seconde page")
    }
}

/// Le drapeau « cette base a un modèle par défaut » est constaté à la liaison,
/// puis rafraîchi à chaque lancement.
///
/// Ce qui manquait : une liaison enregistrée avant que la détection n'existe
/// gardait `false` pour toujours, et les pages naissaient nues sans que rien ne
/// le dise. Le rafraîchissement le rattrape — à condition de ne pas effacer ce
/// qu'on sait déjà quand Notion est simplement injoignable.
final class DefaultTemplateProbeTests: XCTestCase {

    func testOnlyTimeEntriesAreBornFromATemplate() {
        for role in [DatabaseRole.tasks, .projects] {
            XCTAssertFalse(DefaultTemplateProbe.decide(role: role, current: true,
                                                       outcome: .has(true)),
                           "seules les entrées de temps sont créées par l'app")
        }
    }

    func testTheProbeAnswerWins() {
        XCTAssertTrue(DefaultTemplateProbe.decide(role: .timeEntries, current: false,
                                                  outcome: .has(true)))
        XCTAssertFalse(DefaultTemplateProbe.decide(role: .timeEntries, current: true,
                                                   outcome: .has(false)))
    }

    func testAnUnreadableListLeavesWhatIsAlreadyKnown() {
        XCTAssertTrue(DefaultTemplateProbe.decide(role: .timeEntries, current: true,
                                                  outcome: .unreadable),
                      "Notion injoignable au lancement ne doit pas effacer le modèle")
        XCTAssertFalse(DefaultTemplateProbe.decide(role: .timeEntries, current: false,
                                                   outcome: .unreadable))
    }
}

