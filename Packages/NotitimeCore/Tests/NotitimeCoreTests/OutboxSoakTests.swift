import XCTest
@testable import NotitimeCore

/// T090 — campagne SC-004 : 100 sessions enchaînées sous coupures réseau, `429`
/// et arrêts en cours de requête. Zéro entrée perdue, zéro entrée dupliquée.
final class OutboxSoakTests: XCTestCase {

    /// Notion simulé : mémorise les pages créées et les indexe par identifiant
    /// local, ce qui permet de constater un doublon plutôt que de le supposer.
    actor FakeNotion: HTTPTransport {
        struct Dropped: Error {}

        private(set) var createdByLocalID: [String: String] = [:]
        private(set) var creationCount = 0
        private(set) var duplicateAttempts = 0
        /// Scénario d'échecs, consommé requête après requête.
        private var script: [Outcome]
        private var index = 0

        enum Outcome { case ok, dropped, rateLimited, serverError }

        init(script: [Outcome]) { self.script = script }

        private func nextOutcome() -> Outcome {
            defer { index += 1 }
            return script.isEmpty ? .ok : script[index % script.count]
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data()))
                as? [String: Any] ?? [:]

            if request.path.hasSuffix("/query") {
                // Vérification d'idempotence : rendre la page si elle existe.
                let filter = body["filter"] as? [String: Any]
                let text = (filter?["rich_text"] as? [String: Any])?["equals"] as? String
                let found = text.flatMap { createdByLocalID[$0] }
                let results = found.map { #"{"object":"page","id":"\#($0)","properties":{}}"# } ?? ""
                return HTTPResponse(status: 200, headers: [:],
                                    body: Data(#"{"results":[\#(results)],"has_more":false}"#.utf8))
            }

            switch nextOutcome() {
            case .dropped:
                // Coupure pendant la requête : la page peut avoir été créée ou
                // non. Ici on choisit le pire cas — elle l'a été.
                recordCreation(from: body)
                throw Dropped()
            case .rateLimited:
                return HTTPResponse(status: 429, headers: ["Retry-After": "1"], body: Data("{}".utf8))
            case .serverError:
                return HTTPResponse(status: 503, headers: [:], body: Data("{}".utf8))
            case .ok:
                let pageID = recordCreation(from: body)
                return HTTPResponse(status: 200, headers: [:],
                                    body: Data(#"{"object":"page","id":"\#(pageID)"}"#.utf8))
            }
        }

        @discardableResult
        private func recordCreation(from body: [String: Any]) -> String {
            let properties = body["properties"] as? [String: Any] ?? [:]
            let identifier = properties["ID"] as? [String: Any]
            let items = identifier?["rich_text"] as? [[String: Any]]
            let localID = (items?.first?["text"] as? [String: Any])?["content"] as? String ?? "?"

            if createdByLocalID[localID] != nil { duplicateAttempts += 1 }
            creationCount += 1
            let pageID = "page-\(creationCount)"
            createdByLocalID[localID] = createdByLocalID[localID] ?? pageID
            return createdByLocalID[localID] ?? pageID
        }
    }

    private func composer() -> EntryComposer {
        EntryComposer(mapper: PropertyMapper(map: [
            .entryTitle: PropertyRef(id: "title", name: "Name", type: "title"),
            .entryLocalID: PropertyRef(id: "p-lid", name: "ID", type: "rich_text")
        ]), dataSourceID: "ds-te", personUserID: "u-1", taskTitleLookup: { _ in "T" })
    }

    private func entries(_ count: Int) -> [ComposedEntry] {
        let base = ISO8601DateFormatter().date(from: "2026-08-27T08:00:00Z")!
        return (0..<count).map { index in
            ComposedEntry(localID: UUID(), taskPageID: "t-\(index)", title: "T\(index)",
                          startedAt: base.addingTimeInterval(TimeInterval(index * 1800)),
                          endedAt: base.addingTimeInterval(TimeInterval(index * 1800 + 1500)),
                          durationMinutes: 25, mode: .pomodoro, outcome: .ranToTerm,
                          shortenReason: nil, subtractedIdleMinutes: 0)
        }
    }

    /// SC-004 — cent sessions, un réseau hostile, et l'invariant tenu.
    func testHundredSessionsSurviveAHostileNetwork() async throws {
        let notion = FakeNotion(script: [.ok, .dropped, .rateLimited, .ok,
                                         .serverError, .dropped, .ok, .ok])
        let outbox = Outbox(client: NotionClient(transport: notion,
                                                 authorization: StaticAuthorization(),
                                                 rateLimiter: .forTesting(VirtualTimeSource())),
                            composer: composer())

        var queue = Outbox.drainOrder(entries(100))
        var sent: Set<UUID> = []
        var lastOutcome: [UUID: AttemptOutcome] = [:]
        var rounds = 0

        // La file est rejouée jusqu'à épuisement, comme le ferait le drain réel.
        while !queue.isEmpty {
            rounds += 1
            XCTAssertLessThan(rounds, 50, "la file doit converger")

            var remaining: [ComposedEntry] = []
            for entry in queue {
                let previous = lastOutcome[entry.localID] ?? .neverAttempted
                switch await outbox.send(entry, afterAttempt: previous) {
                case .sent:
                    sent.insert(entry.localID)
                case .retryLater(let outcome, _):
                    lastOutcome[entry.localID] = outcome
                    remaining.append(entry)
                case .failedPermanently(let cause):
                    XCTFail("aucun échec définitif attendu : \(cause)")
                }
            }
            queue = remaining
        }

        XCTAssertEqual(sent.count, 100, "aucune entrée perdue")
        let duplicates = await notion.duplicateAttempts
        XCTAssertEqual(duplicates, 0, "aucune entrée dupliquée")
        let distinct = await notion.createdByLocalID.count
        XCTAssertEqual(distinct, 100, "cent pages distinctes dans Notion")
    }

    /// Le pire cas isolé : la coupure survient **après** que Notion a créé la
    /// page. Le réessai doit la retrouver, pas en produire une seconde.
    func testDropAfterCreationDoesNotDuplicate() async throws {
        let notion = FakeNotion(script: [.dropped, .ok])
        let outbox = Outbox(client: NotionClient(transport: notion,
                                                 authorization: StaticAuthorization(),
                                                 rateLimiter: .forTesting(VirtualTimeSource())),
                            composer: composer())
        let entry = entries(1)[0]

        let first = await outbox.send(entry, afterAttempt: .neverAttempted)
        guard case .retryLater(let outcome, _) = first else {
            return XCTFail("attendu un réessai, obtenu \(first)")
        }
        XCTAssertEqual(outcome, .indeterminate)

        let second = await outbox.send(entry, afterAttempt: outcome)

        guard case .sent = second else { return XCTFail("obtenu \(second)") }
        let duplicates = await notion.duplicateAttempts
        XCTAssertEqual(duplicates, 0)
        let distinct = await notion.createdByLocalID.count
        XCTAssertEqual(distinct, 1, "une seule page pour une seule session")
    }
}
