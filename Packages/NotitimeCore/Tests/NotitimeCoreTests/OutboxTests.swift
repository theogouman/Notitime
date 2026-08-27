import XCTest
@testable import NotitimeCore

/// T053, T054 — envoi d'une entrée et publication du commentaire.
///
/// Principe IV : une session ne se perd jamais. L'entrée n'est retirée de la
/// file que sur confirmation, et l'échec du commentaire n'y touche pas.
final class OutboxTests: XCTestCase {

    private func makeClient(_ transport: FixtureTransport) -> NotionClient {
        NotionClient(transport: transport,
                     authorization: StaticAuthorization(),
                     rateLimiter: .forTesting(VirtualTimeSource()))
    }

    private func composer(statusOptions: [String] = []) -> EntryComposer {
        EntryComposer(mapper: PropertyMapper(map: [
            .entryTitle: PropertyRef(id: "title", name: "Name", type: "title"),
            .entryTask: PropertyRef(id: "p-task", name: "Tâches", type: "relation"),
            .entryStart: PropertyRef(id: "p-str", name: "Date de début", type: "date"),
            .entryEnd: PropertyRef(id: "p-end", name: "Date de fin", type: "date"),
            .entryDuration: PropertyRef(id: "p-dur", name: "Durée en min", type: "number"),
            .entryType: PropertyRef(id: "p-met", name: "Méthode", type: "select"),
            .entryStatus: PropertyRef(id: "p-sta", name: "Status", type: "status"),
            .entryPerson: PropertyRef(id: "p-per", name: "Responsable", type: "people"),
            .entryLocalID: PropertyRef(id: "p-lid", name: "ID", type: "rich_text")
        ]), dataSourceID: "ds-time-entries", personUserID: "user-1",
            statusOptions: statusOptions, taskTitleLookup: { _ in "Refonte facturation" })
    }

    private func entry(outcome: SessionOutcome = .ranToTerm,
                       shortenReason: ShortenReason? = nil) -> ComposedEntry {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        return composer().compose(
            CompletedSession(localID: UUID(), taskPageID: "task-1", mode: .pomodoro,
                             startedAt: start, endedAt: start.addingTimeInterval(1500),
                             effectiveSeconds: 1500, outcome: outcome,
                             shortenReason: shortenReason, subtractedIdleSeconds: 0)
        )
    }

    // MARK: - T053 : création de la page

    func testSuccessfulSendCreatesThePageAndReportsItsID() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-created-1"}"#)
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        let result = await outbox.send(entry())

        XCTAssertEqual(result, .sent(pageID: "page-created-1"))
    }

    /// FR-027 — l'entrée ne sort de la file que sur confirmation.
    func testPermanentFailureIsReportedAsDefinitive() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 400,
                                json: #"{"object":"error","code":"validation_error","message":"Statut is expected to be status."}"#)
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        let result = await outbox.send(entry())

        guard case .failedPermanently(let cause) = result else {
            return XCTFail("attendu échec définitif, obtenu \(result)")
        }
        XCTAssertTrue(cause.contains("status") || cause.contains("validation"),
                      "la cause de Notion est conservée, obtenu : \(cause)")
    }

    /// FR-029 — un 429 ou un 5xx se réessaie, il n'abandonne jamais l'entrée.
    func testTransientFailureAsksForARetry() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 503, json: "{}")
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        let result = await outbox.send(entry())

        guard case .retryLater(let attemptOutcome, _) = result else {
            return XCTFail("attendu réessai, obtenu \(result)")
        }
        XCTAssertEqual(attemptOutcome, .explicitError,
                       "Notion a répondu : aucune page créée, pas de vérification au réessai")
    }

    /// FR-028, R-06 — sans réponse, l'issue est **indéterminée** : le réessai
    /// devra vérifier avant de recréer, sous peine de doublon.
    func testTransportFailureIsIndeterminate() async throws {
        struct Dropped: Error {}
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, .failure(Dropped()))
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        let result = await outbox.send(entry())

        guard case .retryLater(let attemptOutcome, _) = result else {
            return XCTFail("attendu réessai, obtenu \(result)")
        }
        XCTAssertEqual(attemptOutcome, .indeterminate)
    }

    // MARK: - T054 : commentaire best-effort (FR-026a)

    /// Le commentaire suit la création, et jamais l'inverse.
    func testCommentIsPostedAfterASuccessfulCreation() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)
        await transport.enqueue(.post, NotionAPI.Path.comments, status: 200, json: "{}")
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        let result = await outbox.send(entry(outcome: .shortened, shortenReason: .user))

        XCTAssertEqual(result, .sent(pageID: "page-1"))
        let recorded = await transport.recorded
        XCTAssertEqual(recorded.map(\.path), [NotionAPI.Path.pages, NotionAPI.Path.comments],
                       "la page d'abord, le commentaire ensuite")
    }

    /// FR-026a — un commentaire refusé ne remet pas l'entrée en file. C'est le
    /// piège : l'entrée existe dans Notion, la rejouer créerait un doublon.
    func testFailedCommentStillCountsAsSent() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)
        await transport.enqueue(.post, NotionAPI.Path.comments, status: 403,
                                json: #"{"object":"error","code":"restricted_resource"}"#)
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        let result = await outbox.send(entry(outcome: .shortened, shortenReason: .user))

        XCTAssertEqual(result, .sent(pageID: "page-1"),
                       "l'entrée est envoyée dès que la page existe")
    }

    /// Aucun commentaire pour une session propre : pas de requête inutile.
    func testNoCommentRequestForACleanSession() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        _ = await outbox.send(entry())

        let recorded = await transport.recorded
        XCTAssertEqual(recorded.count, 1, "une seule requête : la création")
    }

    /// Le commentaire porte le motif — c'est son unique raison d'être.
    func testCommentBodyCarriesTheShorteningReason() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)
        await transport.enqueue(.post, NotionAPI.Path.comments, status: 200, json: "{}")
        let outbox = Outbox(client: makeClient(transport), composer: composer())

        _ = await outbox.send(entry(outcome: .shortened, shortenReason: .user))

        let recorded = await transport.recorded
        let comment = try XCTUnwrap(recorded.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: comment.body ?? Data())
                                    as? [String: Any])
        let parent = try XCTUnwrap(body["parent"] as? [String: Any])
        XCTAssertEqual(parent["page_id"] as? String, "page-1")
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: body),
                                as: UTF8.self)
        XCTAssertTrue(serialized.contains("utilisateur"), "obtenu : \(serialized)")
    }
}

/// Toute tentative d'envoi doit laisser une trace de son **issue**.
///
/// En production, le journal s'arrêtait à « envoi entrée=… » : le chemin
/// heureux était instrumenté, les échecs non. Un envoi qui échoue est
/// exactement le cas où la trace compte.
final class OutboxLoggingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notitime-outbox-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeOutbox(_ transport: FixtureTransport, log: SessionLog) -> Outbox {
        Outbox(client: NotionClient(transport: transport,
                                    authorization: StaticAuthorization(),
                                    rateLimiter: .forTesting(VirtualTimeSource())),
               composer: EntryComposer(mapper: PropertyMapper(map: [
                    .entryTitle: PropertyRef(id: "title", name: "Name", type: "title"),
                    .entryTask: PropertyRef(id: "p-task", name: "Tâches", type: "relation")
               ]), dataSourceID: "ds", personUserID: "u-1", taskTitleLookup: { _ in "T" }),
               log: log)
    }

    private func entry() -> ComposedEntry {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        return ComposedEntry(localID: UUID(), taskPageID: "t-1", title: "T",
                             startedAt: start, endedAt: start.addingTimeInterval(300),
                             durationMinutes: 5, mode: .pomodoro, outcome: .ranToTerm,
                             shortenReason: nil, subtractedIdleMinutes: 0)
    }

    func testPermanentFailureIsLogged() async throws {
        let log = SessionLog(directory: directory, time: VirtualTimeSource())
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 400,
                                json: #"{"object":"error","code":"validation_error","message":"Status is expected to be status."}"#)

        _ = await makeOutbox(transport, log: log).send(entry())

        let contents = await log.exportedContents()
        XCTAssertTrue(contents.contains("définitif") || contents.contains("refusé"),
                      "l'échec définitif doit être tracé, obtenu : \(contents)")
        XCTAssertTrue(contents.contains("400") || contents.contains("validation"),
                      "avec la cause, obtenu : \(contents)")
    }

    func testRetryableFailureIsLogged() async throws {
        let log = SessionLog(directory: directory, time: VirtualTimeSource())
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 503, json: "{}")

        _ = await makeOutbox(transport, log: log).send(entry())

        let contents = await log.exportedContents()
        XCTAssertTrue(contents.contains("réessayer"), "obtenu : \(contents)")
        XCTAssertTrue(contents.contains("explicitError"),
                      "l'issue de la tentative décide du réessai : elle doit figurer")
    }

    /// L'identifiant de page créée est ce qui permet de retrouver l'entrée dans
    /// Notion depuis le journal : il ne doit pas manquer.
    func testSuccessLogsTheCreatedPageID() async throws {
        let log = SessionLog(directory: directory, time: VirtualTimeSource())
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-abc"}"#)

        _ = await makeOutbox(transport, log: log).send(entry())

        let contents = await log.exportedContents()
        XCTAssertTrue(contents.contains("page-abc"), "obtenu : \(contents)")
    }
}

/// L'envoi ne doit jamais dépendre du cycle de vie de l'appelant.
///
/// En production, la fin d'un pomodoro annulait la tâche du minuteur puis
/// lançait l'envoi **depuis cette même tâche** : `URLSession` abandonnait
/// aussitôt la requête (`NSURLErrorCancelled`), et l'entrée n'atteignait jamais
/// Notion. Principe IV : une session ne se perd jamais.
final class OutboxCancellationTests: XCTestCase {

    private func makeOutbox(_ transport: HTTPTransport) -> Outbox {
        Outbox(client: NotionClient(transport: transport,
                                    authorization: StaticAuthorization(),
                                    rateLimiter: .forTesting(VirtualTimeSource())),
               composer: EntryComposer(mapper: PropertyMapper(map: [
                    .entryTitle: PropertyRef(id: "title", name: "Name", type: "title")
               ]), dataSourceID: "ds", personUserID: "u-1", taskTitleLookup: { _ in "T" }))
    }

    private func entry() -> ComposedEntry {
        let start = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!
        return ComposedEntry(localID: UUID(), taskPageID: "t-1", title: "T",
                             startedAt: start, endedAt: start.addingTimeInterval(300),
                             durationMinutes: 5, mode: .pomodoro, outcome: .ranToTerm,
                             shortenReason: nil, subtractedIdleMinutes: 0)
    }

    private func fixture() async -> FixtureTransport {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.pages, status: 200,
                                json: #"{"object":"page","id":"page-1"}"#)
        return transport
    }

    /// Le défaut, reproduit : depuis une tâche annulée, l'envoi n'aboutit pas.
    func testSendFromACancelledTaskFails() async throws {
        let transport = CancellationAwareTransport(await fixture())
        let outbox = makeOutbox(transport)
        let entry = entry()

        let task = Task { () -> SendResult in
            // L'appelant s'annule lui-même avant d'envoyer, exactement comme le
            // minuteur le faisait en fin de session.
            withUnsafeCurrentTask { $0?.cancel() }
            return await outbox.send(entry)
        }
        let result = await task.value

        guard case .retryLater(let outcome, _) = result else {
            return XCTFail("attendu un réessai, obtenu \(result)")
        }
        XCTAssertEqual(outcome, .indeterminate)
    }

    /// La garantie attendue : l'envoi détaché aboutit malgré l'annulation.
    func testDetachedSendSurvivesCallerCancellation() async throws {
        let transport = CancellationAwareTransport(await fixture())
        let outbox = makeOutbox(transport)
        let entry = entry()

        let task = Task { () -> SendResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await outbox.sendDetached(entry)
        }
        let result = await task.value

        XCTAssertEqual(result, .sent(pageID: "page-1"),
                       "l'entrée doit partir même si l'appelant a été annulé")
    }
}
