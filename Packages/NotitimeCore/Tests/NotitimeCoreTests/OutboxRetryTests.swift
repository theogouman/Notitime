import XCTest
@testable import NotitimeCore

/// T086 à T089, T091 — idempotence conditionnelle, classement des erreurs,
/// backoff. Principe IV : aucune entrée perdue, aucune entrée dupliquée.
final class OutboxRetryTests: XCTestCase {

    private let mapping: [PropertyKey: PropertyRef] = [
        .entryTitle: PropertyRef(id: "title", name: "Name", type: "title"),
        .entryTask: PropertyRef(id: "p-task", name: "Tâches", type: "relation"),
        .entryLocalID: PropertyRef(id: "p-lid", name: "ID", type: "rich_text")
    ]

    private func makeOutbox(_ transport: FixtureTransport) -> Outbox {
        Outbox(client: NotionClient(transport: transport,
                                    authorization: StaticAuthorization(),
                                    rateLimiter: .forTesting(VirtualTimeSource())),
               composer: EntryComposer(mapper: PropertyMapper(map: mapping),
                                       dataSourceID: "ds-te", personUserID: "u-1",
                                       taskTitleLookup: { _ in "T" }))
    }

    private func entry() -> ComposedEntry {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        return ComposedEntry(localID: UUID(), taskPageID: "t-1", title: "T",
                             startedAt: start, endedAt: start.addingTimeInterval(300),
                             durationMinutes: 5, mode: .pomodoro, outcome: .ranToTerm,
                             shortenReason: nil, subtractedIdleMinutes: 0)
    }

    private var queryPath: String { NotionAPI.Path.queryDataSource("ds-te") }

    // MARK: - T086 : vérification conditionnelle

    /// FR-028 — une première tentative crée directement, sans rien vérifier.
    func testFirstAttemptCreatesWithoutChecking() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)

        _ = await makeOutbox(transport).send(entry(), afterAttempt: .neverAttempted)

        let checks = await transport.requestCount(.post, queryPath)
        XCTAssertEqual(checks, 0, "aucune vérification à la première tentative")
    }

    /// FR-028 — après une erreur **explicite**, aucune vérification : la réponse
    /// de Notion prouve qu'aucune page n'a été créée.
    func testExplicitErrorRetryDoesNotCheck() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)

        _ = await makeOutbox(transport).send(entry(), afterAttempt: .explicitError)

        let checks = await transport.requestCount(.post, queryPath)
        XCTAssertEqual(checks, 0)
    }

    /// FR-028, R-06 — après une issue **indéterminée**, on vérifie avant de
    /// recréer. C'est le seul cas où un doublon serait possible.
    func testIndeterminateRetryChecksBeforeCreating() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, queryPath, status: 200, json: #"{"results":[],"has_more":false}"#)
        await transport.enqueue(.post, queryPath, status: 200, json: #"{"results":[],"has_more":false}"#)
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)

        let result = await makeOutbox(transport).send(entry(), afterAttempt: .indeterminate)

        XCTAssertEqual(result, .sent(pageID: "page-1"))
        let checks = await transport.requestCount(.post, queryPath)
        XCTAssertEqual(checks, 2, "double interrogation : hors corbeille, puis dedans")
    }

    /// L'entrée existe déjà : on ne la recrée pas, et l'envoi est réputé fait.
    func testExistingEntryIsNotRecreated() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, queryPath, status: 200,
                                json: #"{"results":[{"object":"page","id":"page-déjà","properties":{}}],"has_more":false}"#)

        let result = await makeOutbox(transport).send(entry(), afterAttempt: .indeterminate)

        XCTAssertEqual(result, .sent(pageID: "page-déjà"))
        let creations = await transport.requestCount(.post, NotionAPI.Path.pages)
        XCTAssertEqual(creations, 0, "aucune page recréée")
    }

    /// T091 — une entrée archivée entre-temps est détectée par la **seconde**
    /// interrogation. Sans elle, une entrée mise à la corbeille serait recréée.
    func testArchivedEntryIsDetectedBySecondQuery() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, queryPath, status: 200, json: #"{"results":[],"has_more":false}"#)
        await transport.enqueue(.post, queryPath, status: 200,
                                json: #"{"results":[{"object":"page","id":"page-archivée","properties":{}}],"has_more":false}"#)

        let result = await makeOutbox(transport).send(entry(), afterAttempt: .indeterminate)

        XCTAssertEqual(result, .sent(pageID: "page-archivée"))
        let creations = await transport.requestCount(.post, NotionAPI.Path.pages)
        XCTAssertEqual(creations, 0)
    }

    /// La vérification filtre sur la propriété d'identifiant local, pas sur autre
    /// chose : c'est elle qui porte la clé de déduplication.
    func testCheckFiltersOnTheLocalIdentifier() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, queryPath, status: 200, json: #"{"results":[],"has_more":false}"#)
        await transport.enqueue(.post, queryPath, status: 200, json: #"{"results":[],"has_more":false}"#)
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)
        let entry = entry()

        _ = await makeOutbox(transport).send(entry, afterAttempt: .indeterminate)

        let recorded = await transport.recorded
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded[0].body ?? Data())
                                    as? [String: Any])
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: body),
                                as: UTF8.self)
        XCTAssertTrue(serialized.contains(entry.localID.uuidString), "obtenu : \(serialized)")
        XCTAssertTrue(serialized.contains("\"ID\""), "filtre sur la propriété ID")
    }

    /// Une vérification qui échoue ne doit pas créer à l'aveugle : on préfère
    /// réessayer plus tard plutôt que risquer un doublon.
    func testFailedCheckDefersRatherThanCreating() async throws {
        struct Offline: Error {}
        let transport = FixtureTransport()
        await transport.enqueue(.post, queryPath, .failure(Offline()))

        let result = await makeOutbox(transport).send(entry(), afterAttempt: .indeterminate)

        guard case .retryLater(let outcome, _) = result else {
            return XCTFail("obtenu \(result)")
        }
        XCTAssertEqual(outcome, .indeterminate, "l'incertitude demeure")
        let creations = await transport.requestCount(.post, NotionAPI.Path.pages)
        XCTAssertEqual(creations, 0)
    }

    // MARK: - T088 : classement des erreurs

    func testPermanentStatusesFailImmediately() async throws {
        for status in [400, 403, 404] {
            let transport = FixtureTransport()
            await transport.enqueue(.post, NotionAPI.Path.pages, status: status,
                                    json: #"{"object":"error","code":"e","message":"refus"}"#)

            let result = await makeOutbox(transport).send(entry())

            guard case .failedPermanently = result else {
                return XCTFail("statut \(status) : attendu un échec définitif, obtenu \(result)")
            }
        }
    }

    func testTransientStatusesAskForARetry() async throws {
        for status in [429, 500, 502, 503] {
            let transport = FixtureTransport()
            await transport.enqueue(.post, NotionAPI.Path.pages, status: status, json: "{}")

            let result = await makeOutbox(transport).send(entry())

            guard case .retryLater = result else {
                return XCTFail("statut \(status) : attendu un réessai, obtenu \(result)")
            }
        }
    }

    // MARK: - T094 : backoff

    /// FR-029 — le délai croît puis plafonne, et n'abandonne jamais.
    func testBackoffGrowsAndIsCapped() {
        let delays = (1...12).map { Outbox.retryDelay(forAttempt: $0) }

        XCTAssertEqual(delays[0], .seconds(2))
        for index in 1..<delays.count {
            XCTAssertGreaterThanOrEqual(delays[index], delays[index - 1], "le délai ne décroît pas")
        }
        XCTAssertEqual(delays.last, Outbox.maximumRetryDelay, "il plafonne")
        XCTAssertLessThanOrEqual(Outbox.maximumRetryDelay, .seconds(600))
    }

    /// Un `Retry-After` de Notion prime sur le backoff calculé.
    func testRetryAfterOverridesTheComputedDelay() {
        XCTAssertEqual(Outbox.retryDelay(forAttempt: 1, retryAfter: .seconds(42)), .seconds(42))
        XCTAssertEqual(Outbox.retryDelay(forAttempt: 9, retryAfter: .seconds(1)), .seconds(1),
                       "même plus court que le backoff : Notion fait autorité")
    }

    // MARK: - T089 : ordre de vidage

    /// US6.2 — la file se vide dans l'ordre chronologique des sessions.
    func testQueueDrainsInChronologicalOrder() {
        let base = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        let entries = [2, 0, 1].map { offset in
            ComposedEntry(localID: UUID(), taskPageID: "t", title: "T",
                          startedAt: base.addingTimeInterval(TimeInterval(offset * 600)),
                          endedAt: base.addingTimeInterval(TimeInterval(offset * 600 + 300)),
                          durationMinutes: 5, mode: .pomodoro, outcome: .ranToTerm,
                          shortenReason: nil, subtractedIdleMinutes: 0)
        }

        let ordered = Outbox.drainOrder(entries)

        XCTAssertEqual(ordered.map(\.startedAt),
                       entries.map(\.startedAt).sorted(),
                       "la plus ancienne part la première")
    }
}
