import XCTest
@testable import NotitimeCore

/// FR-029 : l'application limite son propre débit à 3 requêtes par seconde et
/// respecte le `Retry-After` renvoyé par Notion.
final class RateLimiterTests: XCTestCase {

    func testNeverExceedsThreeRequestsInAnySlidingSecond() async throws {
        let time = VirtualTimeSource()
        let limiter = RateLimiter(time: time)

        var timestamps: [Double] = []
        for _ in 0..<12 {
            try await limiter.acquire()
            timestamps.append(time.monotonic.seconds)
        }

        // Lecture stricte : dans toute fenêtre glissante d'une seconde ouverte sur
        // une acquisition, au plus trois acquisitions. Un seau autorisant la rafale
        // passerait à six et violerait la limite Notion.
        for (index, start) in timestamps.enumerated() {
            let inWindow = timestamps[index...].prefix { $0 < start + 1.0 }.count
            XCTAssertLessThanOrEqual(inWindow, 3,
                                     "fenêtre ouverte à \(start)s : \(inWindow) requêtes")
        }
    }

    func testFirstAcquisitionIsImmediate() async throws {
        let time = VirtualTimeSource()
        let limiter = RateLimiter(time: time)

        try await limiter.acquire()

        XCTAssertEqual(time.monotonic, .zero, "la première requête ne doit pas attendre")
    }

    func testRetryAfterSuspendsTheWholeBucket() async throws {
        let time = VirtualTimeSource()
        let limiter = RateLimiter(time: time)

        try await limiter.acquire()
        await limiter.suspend(for: .seconds(30))
        try await limiter.acquire()

        // Suspendre la seule requête fautive laisserait une requête concurrente
        // repartir immédiatement dans le mur : c'est le seau entier qui est gelé.
        XCTAssertGreaterThanOrEqual(time.monotonic.seconds, 30.0)
    }

    func testLongerSuspensionWins() async throws {
        let time = VirtualTimeSource()
        let limiter = RateLimiter(time: time)

        await limiter.suspend(for: .seconds(60))
        await limiter.suspend(for: .seconds(5))
        try await limiter.acquire()

        XCTAssertGreaterThanOrEqual(time.monotonic.seconds, 60.0,
                                    "une suspension plus courte ne doit pas raccourcir la plus longue")
    }

    func testRetryAfterHeaderParsing() {
        XCTAssertEqual(ResponseClassifier.parseRetryAfter("12"), .seconds(12))
        XCTAssertEqual(ResponseClassifier.parseRetryAfter(" 0.5 "), .seconds(0.5))
        XCTAssertNil(ResponseClassifier.parseRetryAfter(nil))
        XCTAssertNil(ResponseClassifier.parseRetryAfter("bientôt"))
    }
}

/// FR-029 : classement des réponses, et FR-028 : ce que chaque classe prouve
/// quant à l'existence d'une page côté Notion.
final class ResponseClassifierTests: XCTestCase {

    func testTransientAndPermanentClasses() {
        XCTAssertEqual(ResponseClassifier.classify(status: 200), .success)
        XCTAssertEqual(ResponseClassifier.classify(status: 401), .unauthorized)
        XCTAssertEqual(ResponseClassifier.classify(status: 400), .permanent(.validation))
        XCTAssertEqual(ResponseClassifier.classify(status: 403), .permanent(.forbidden))
        XCTAssertEqual(ResponseClassifier.classify(status: 404), .permanent(.notFound))
        XCTAssertEqual(ResponseClassifier.classify(status: 500), .transient(retryAfter: nil))
        XCTAssertEqual(ResponseClassifier.classify(status: 429, retryAfterHeader: "7"),
                       .transient(retryAfter: .seconds(7)))
    }

    func testOnlyExplicitErrorsProveNoPageWasCreated() {
        // C'est cette propriété qui dispense un réessai de la vérification
        // d'idempotence : une erreur explicite prouve qu'aucune page n'existe.
        XCTAssertTrue(ResponseClassifier.classify(status: 400).provesNoSideEffect)
        XCTAssertTrue(ResponseClassifier.classify(status: 403).provesNoSideEffect)
        XCTAssertTrue(ResponseClassifier.classify(status: 404).provesNoSideEffect)
        XCTAssertTrue(ResponseClassifier.classify(status: 401).provesNoSideEffect)

        // Une absence de réponse ou un 5xx ne prouve rien : l'issue reste indéterminée.
        XCTAssertFalse(ResponseClassifier.classify(status: 500).provesNoSideEffect)
        XCTAssertFalse(ResponseClassifier.classify(transportError: URLError(.timedOut)).provesNoSideEffect)
    }

    func testAttemptOutcomeGatesTheIdempotencyCheck() {
        // Invariant 4 de contracts/core-api.md : la vérification n'est émise que
        // dans le cas indéterminé, jamais à la première tentative ni après erreur.
        XCTAssertFalse(AttemptOutcome.neverAttempted.requiresIdempotencyCheck)
        XCTAssertFalse(AttemptOutcome.explicitError.requiresIdempotencyCheck)
        XCTAssertTrue(AttemptOutcome.indeterminate.requiresIdempotencyCheck)
    }
}
