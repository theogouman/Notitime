import XCTest
import SwiftData
@testable import NotitimeCore

/// Vérifie que le schéma déclaré se charge et que les accesseurs typés des modèles
/// se comportent comme `data-model.md` les décrit. Sans cette vérification, T017
/// serait « fait » sans preuve que le magasin s'ouvre.
final class PersistenceSmokeTests: XCTestCase {

    func testInMemoryContainerLoadsTheWholeSchema() throws {
        let container = try NotitimeStore.makeInMemoryContainer()
        XCTAssertEqual(container.schema.entities.count, NotitimeStore.schema.entities.count)
    }

    @MainActor
    func testOutboxEntryRoundTrip() throws {
        let container = try NotitimeStore.makeInMemoryContainer()
        let context = container.mainContext
        let id = UUID()

        let entry = OutboxEntry(localID: id, taskPageID: "task-1", title: "Refonte — 25 min",
                                startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                                endedAt: Date(timeIntervalSince1970: 1_756_001_500),
                                durationMinutes: 25, mode: .pomodoro, outcome: .ranToTerm)
        context.insert(entry)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.attemptOutcome, .neverAttempted)
        XCTAssertEqual(fetched.first?.sendState, .pending)
        XCTAssertFalse(fetched.first?.needsComment ?? true,
                       "une session allée à son terme sans retranchement ne porte pas de commentaire")
    }

    @MainActor
    func testShortenedSessionMapsToNotionStatusAndNeedsComment() throws {
        let container = try NotitimeStore.makeInMemoryContainer()
        let context = container.mainContext

        let entry = OutboxEntry(localID: UUID(), taskPageID: "task-1", title: "t",
                                startedAt: Date(), endedAt: Date(), durationMinutes: 4,
                                mode: .pomodoro, outcome: .shortened, shortenReason: .sleep)
        context.insert(entry)
        try context.save()

        XCTAssertEqual(entry.outcome.notionStatus, "Écourté")
        XCTAssertEqual(SessionOutcome.ranToTerm.notionStatus, "Complété")
        XCTAssertNil(SessionOutcome.ignored.notionStatus, "une session ignorée ne produit aucune entrée")
        XCTAssertTrue(entry.needsComment)
        XCTAssertEqual(entry.shortenReason, .sleep)
    }

    @MainActor
    func testActiveSessionIntervalsSurvivePersistence() throws {
        let container = try NotitimeStore.makeInMemoryContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_756_000_000)
        let pause = DateInterval(start: start.addingTimeInterval(60), duration: 30)

        let session = ActiveSession(localID: UUID(), taskPageID: "task-1", mode: .tracker,
                                    startedAt: start, pauseIntervals: [pause],
                                    lastHeartbeatAt: start)
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ActiveSession>()).first
        XCTAssertEqual(fetched?.pauseIntervals, [pause])
        XCTAssertEqual(fetched?.state, .running)
    }

    @MainActor
    func testDefaultSettingsMatchTheSpecification() throws {
        let settings = AppSettings()
        // FR-018 et FR-024 : les valeurs par défaut doivent permettre d'utiliser
        // l'app sans jamais ouvrir les réglages.
        XCTAssertEqual(settings.sessionDurations, [20, 30, 50])
        XCTAssertEqual(settings.shortBreakMinutes, 5)
        XCTAssertEqual(settings.longBreakMinutes, 15)
        XCTAssertEqual(settings.pomodorosBeforeLongBreak, 4)
        XCTAssertEqual(settings.idleThresholdMinutes, 5)
        XCTAssertTrue(settings.idleDetectionEnabledTracker)
        XCTAssertFalse(settings.idleDetectionEnabledPomodoro)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.taskRefreshIntervalMinutes, 5)
    }

    func testLocalIDPropertyDefaultName() {
        XCTAssertEqual(NotionAPI.defaultLocalIDPropertyName, "ID")
        XCTAssertEqual(NotionAPI.version, "2026-03-11")
    }
}
