import XCTest
@testable import NotitimeCore

/// T045 à T047, T049 — machine à états du mode Pomodoro.
///
/// Toutes les durées passent par une horloge virtuelle : la suite complète doit
/// rester de l'ordre de la seconde (principe VII).
final class PomodoroMachineTests: XCTestCase {

    private let task = "task-page-1"

    private func makeMachine(
        time: VirtualTimeSource = VirtualTimeSource(),
        persistence: RecordingSessionPersistence = RecordingSessionPersistence(),
        settings: SessionSettings = SessionSettings()
    ) -> (SessionMachine, VirtualTimeSource, RecordingSessionPersistence) {
        (SessionMachine(time: time, persistence: persistence, settings: settings),
         time, persistence)
    }

    // MARK: - T045 : terme, unicité, tâche obligatoire

    /// Le compte à rebours arrive à zéro : la session est « Complété » et sa
    /// durée est la durée **cible**, pas le temps écoulé au tick près.
    func testCountdownReachingZeroCompletesAtTargetDuration() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(1500))
        let result = await machine.handle(.tick)

        guard case .finished(let session, _) = result else {
            return XCTFail("attendu terminé, obtenu \(result)")
        }
        XCTAssertEqual(session.outcome, .ranToTerm)
        XCTAssertEqual(session.effectiveSeconds, 1500)
        XCTAssertEqual(session.taskPageID, task)
        XCTAssertEqual(session.mode, .pomodoro)
    }

    /// Un tick qui dépasse la cible — l'app était endormie, le tick a été
    /// retardé — ne gonfle pas la durée enregistrée au-delà du pomodoro demandé.
    func testOvershootingTickDoesNotInflateTheRecordedDuration() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(1800))
        let result = await machine.handle(.tick)

        guard case .finished(let session, _) = result else {
            return XCTFail("attendu terminé, obtenu \(result)")
        }
        XCTAssertEqual(session.effectiveSeconds, 1500, "la durée cible fait foi")
    }

    /// FR-017 — une seule session active. Un second démarrage est refusé et
    /// **ne touche pas** à la session en cours.
    func testASecondStartIsRefusedWhileASessionRuns() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(300))
        let refused = await machine.handle(.start(taskPageID: "autre-tâche", mode: .pomodoro,
                                                  target: .seconds(1500)))

        XCTAssertEqual(refused, .refused(.alreadyRunning))
        let snapshot = await machine.snapshot
        XCTAssertEqual(snapshot?.taskPageID, task, "la session en cours est intacte")
    }

    /// FR-015 — pas de tâche, pas de session.
    func testStartIsRefusedWithoutATask() async throws {
        let (machine, _, _) = makeMachine()

        let result = await machine.handle(.start(taskPageID: "", mode: .pomodoro,
                                                 target: .seconds(1500)))

        XCTAssertEqual(result, .refused(.noTaskSelected))
        let snapshot = await machine.snapshot
        XCTAssertNil(snapshot)
    }

    // MARK: - T046 : la règle des 60 secondes

    /// FR-023 — sous 60 s, aucune entrée n'est produite.
    func testSessionShorterThanSixtySecondsProducesNoEntry() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(59))
        let result = await machine.handle(.stopByUser)

        XCTAssertEqual(result, .ignored(effectiveSeconds: 59))
        let snapshot = await machine.snapshot
        XCTAssertNil(snapshot, "la session est close, pas laissée en suspens")
    }

    /// La borne est inclusive : 60 s exactement produit bien une entrée.
    func testExactlySixtySecondsProducesAnEntry() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(60))
        let result = await machine.handle(.stopByUser)

        guard case .finished(let session, _) = result else {
            return XCTFail("attendu terminé, obtenu \(result)")
        }
        XCTAssertEqual(session.outcome, .shortened)
        XCTAssertEqual(session.effectiveSeconds, 60)
    }

    /// Une session ignorée ne casse pas la série : elle n'a pas eu lieu.
    func testIgnoredSessionLeavesTheStreakUntouched() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(60)))
        time.advance(by: .seconds(60))
        _ = await machine.handle(.tick)
        let streak = await machine.streak
        XCTAssertEqual(streak, 1)

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(10))
        _ = await machine.handle(.stopByUser)

        let streak2 = await machine.streak
        XCTAssertEqual(streak2, 1, "une session ignorée n'est pas un écourtement")
    }

    // MARK: - T047 : série et pauses

    /// FR-020 — pause longue au N-ième pomodoro **allé à son terme**.
    func testLongBreakAfterTheConfiguredNumberOfCompletedPomodoros() async throws {
        var settings = SessionSettings()
        settings.pomodorosBeforeLongBreak = 4
        let (machine, time, _) = makeMachine(settings: settings)

        var breaks: [BreakKind] = []
        for _ in 1...4 {
            await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
            time.advance(by: .seconds(1500))
            guard case .finished(_, let suggestion) = await machine.handle(.tick),
                  let suggestion else { return XCTFail("une pause doit être proposée") }
            breaks.append(suggestion)
        }

        XCTAssertEqual(breaks.map(\.isLong), [false, false, false, true],
                       "la pause longue tombe au quatrième, pas avant")
        let streak = await machine.streak
        XCTAssertEqual(streak, 0, "la série repart après une pause longue")
    }

    /// Un pomodoro écourté remet la série à zéro (FR-020).
    func testShortenedPomodoroResetsTheStreak() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(1500))
        _ = await machine.handle(.tick)
        let streak = await machine.streak
        XCTAssertEqual(streak, 1)

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(300))
        _ = await machine.handle(.stopByUser)

        let streak2 = await machine.streak
        XCTAssertEqual(streak2, 0)
    }

    /// Un pomodoro écourté ne propose aucune pause : il n'y a rien à récompenser.
    func testShortenedPomodoroSuggestsNoBreak() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(300))
        let result = await machine.handle(.stopByUser)

        guard case .finished(_, let suggestion) = result else {
            return XCTFail("attendu terminé, obtenu \(result)")
        }
        XCTAssertNil(suggestion)
    }

    /// FR-020 — une pause ne produit jamais d'entrée, si longue soit-elle.
    func testABreakNeverProducesAnEntry() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(1500))
        _ = await machine.handle(.tick)

        await machine.handle(.startBreak(.short(.seconds(300))))
        time.advance(by: .seconds(300))
        let result = await machine.handle(.tick)

        XCTAssertEqual(result, .breakEnded, "une pause se termine, elle ne se comptabilise pas")
    }

    /// Une pause interrompue pour repartir immédiatement ne produit rien non plus.
    func testInterruptingABreakProducesNoEntry() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(1500))
        _ = await machine.handle(.tick)

        await machine.handle(.startBreak(.short(.seconds(300))))
        time.advance(by: .seconds(90))
        let result = await machine.handle(.stopByUser)

        XCTAssertEqual(result, .breakEnded)
    }

    /// FR-018 — le mode Pomodoro n'a pas de pause manuelle en cours de session.
    func testPomodoroRefusesAManualPause() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(300))
        let result = await machine.handle(.pause)

        XCTAssertEqual(result, .refused(.pauseUnavailableInPomodoro))
        let snapshot = await machine.snapshot
        XCTAssertEqual(snapshot?.state, .running, "la session continue de courir")
    }

    // MARK: - T049 : persistance à chaque transition

    /// FR-022 — l'état est réécrit **avant** que le contrôle ne revienne à
    /// l'appelant. Un arrêt inopiné juste après un démarrage doit retrouver la
    /// session, pas un magasin vide.
    func testEveryTransitionPersistsBeforeReturning() async throws {
        let (machine, time, persistence) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        let afterStartCount = await persistence.writeCount
        XCTAssertEqual(afterStartCount, 1)
        let afterStart = await persistence.stored
        XCTAssertEqual(afterStart??.taskPageID, task, "l'état est déjà écrit au retour")

        time.advance(by: .seconds(60))
        await machine.handle(.tick)
        let afterTickCount = await persistence.writeCount
        XCTAssertEqual(afterTickCount, 2, "un tick est une transition")

        time.advance(by: .seconds(1440))
        _ = await machine.handle(.tick)
        let afterEndCount = await persistence.writeCount
        XCTAssertEqual(afterEndCount, 3)
        let afterEnd = await persistence.stored
        XCTAssertEqual(afterEnd, .some(nil), "la session close est effacée, pas laissée derrière")
    }

    /// Le battement de cœur avance à chaque tick : c'est lui qui datera la fin
    /// d'une session retrouvée après un arrêt inopiné (US5.6).
    func testHeartbeatAdvancesOnEveryTick() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        let first = await machine.snapshot?.lastHeartbeatAt
        time.advance(by: .seconds(30))
        await machine.handle(.tick)
        let second = await machine.snapshot?.lastHeartbeatAt

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(try XCTUnwrap(second), try XCTUnwrap(first))
    }
}

private extension BreakKind {
    var isLong: Bool { if case .long = self { return true }; return false }
}
