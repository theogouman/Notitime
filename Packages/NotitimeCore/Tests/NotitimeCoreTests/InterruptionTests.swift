import XCTest
@testable import NotitimeCore

/// T074 à T077 — écourtement, veille, inactivité, restauration après arrêt
/// inopiné. Ce qui garantit que Notion reflète le temps réellement travaillé
/// même quand la session ne se déroule pas normalement.
final class InterruptionTests: XCTestCase {

    private let task = "task-page-1"

    private func makeMachine(
        settings: SessionSettings = SessionSettings(),
        persistence: RecordingSessionPersistence = RecordingSessionPersistence()
    ) -> (SessionMachine, VirtualTimeSource, RecordingSessionPersistence) {
        let time = VirtualTimeSource()
        return (SessionMachine(time: time, persistence: persistence, settings: settings),
                time, persistence)
    }

    // MARK: - T074 : écourtement par l'utilisateur

    /// US5.1 — arrêt manuel d'un pomodoro : « Écourté », motif en commentaire,
    /// série remise à zéro.
    func testUserStopShortensAndResetsTheStreak() async throws {
        let (machine, time, _) = makeMachine()

        // Un premier pomodoro complet pour établir une série.
        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        await beat(machine, time, for: 1500)

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(400))
        let result = await machine.handle(.stopByUser)

        guard case .finished(let session, let suggestion) = result else {
            return XCTFail("obtenu \(result)")
        }
        XCTAssertEqual(session.outcome, .shortened)
        XCTAssertEqual(session.shortenReason, .user)
        XCTAssertEqual(session.effectiveSeconds, 400)
        XCTAssertNil(suggestion, "aucune pause après un pomodoro écourté")
        let streak = await machine.streak
        XCTAssertEqual(streak, 0)
    }

    /// Le motif d'écourtement est ce que le commentaire publiera (FR-026a).
    func testShorteningReasonReachesTheComment() {
        let composer = EntryComposer(mapper: PropertyMapper(map: [:]), dataSourceID: "ds",
                                     personUserID: "u-1", taskTitleLookup: { _ in "T" })
        let start = Date(timeIntervalSince1970: 1_000_000)

        for (reason, fragment) in [(ShortenReason.user, "utilisateur"),
                                   (.sleep, "veille"),
                                   (.unexpectedQuit, "inopiné")] {
            let session = CompletedSession(localID: UUID(), taskPageID: "t", mode: .pomodoro,
                                           startedAt: start, endedAt: start.addingTimeInterval(300),
                                           effectiveSeconds: 300, outcome: .shortened,
                                           shortenReason: reason, subtractedIdleSeconds: 0)
            let comment = composer.comment(for: composer.compose(session))
            XCTAssertNotNil(comment)
            XCTAssertTrue(comment?.contains(fragment) == true,
                          "motif \(reason) : obtenu \(comment ?? "nil")")
        }
    }

    // MARK: - T075 : veille

    /// US5.3 — un pomodoro est clôturé **à l'instant de la veille**, pas à
    /// l'heure du réveil : les heures dormies ne sont pas du travail.
    func testSleepClosesAPomodoroDatedAtSleepTime() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(600))
        let sleepInstant = time.wallClock
        let result = await machine.handle(.systemWillSleep)

        guard case .finished(let session, _) = result else {
            return XCTFail("obtenu \(result)")
        }
        XCTAssertEqual(session.outcome, .shortened)
        XCTAssertEqual(session.shortenReason, .sleep)
        XCTAssertEqual(session.endedAt, sleepInstant)
        XCTAssertEqual(session.effectiveSeconds, 600)
    }

    /// US4.4 — un Tracker est mis en pause par la veille, pas clôturé.
    func testSleepOnlyPausesATracker() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(300))
        let result = await machine.handle(.systemWillSleep)

        XCTAssertEqual(result, .none)
        let snapshot = await machine.snapshot
        XCTAssertEqual(snapshot?.state, .paused)
    }

    /// FR-022 — l'état est écrit avant l'endormissement, sans quoi la veille
    /// emporterait la dernière transition.
    func testStateIsPersistedBeforeSleeping() async throws {
        let (machine, time, persistence) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(300))
        let before = await persistence.writeCount
        await machine.handle(.systemWillSleep)

        let after = await persistence.writeCount
        XCTAssertGreaterThan(after, before, "la veille est une transition comme une autre")
    }

    // MARK: - T076 : inactivité

    /// US5.4, FR-024 — le retranchement réduit la durée sans changer le résultat.
    /// Un pomodoro allé à son terme reste « Complété », et la série tient.
    func testSubtractingIdleKeepsTheOutcomeAndTheStreak() async throws {
        var settings = SessionSettings()
        settings.idleDetectionInPomodoro = true
        let (machine, time, _) = makeMachine(settings: settings)

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(600))
        await machine.handle(.idleDetected(seconds: 300))
        let result = await beat(machine, time, for: 900)

        guard case .finished(let session, _) = result else { return XCTFail("obtenu \(result)") }
        XCTAssertEqual(session.outcome, .ranToTerm, "le pomodoro est bien allé à son terme")
        XCTAssertEqual(session.pendingIdleSeconds, 300, "l'arbitrage revient à l'utilisateur")

        let subtracted = session.subtractingIdle()
        XCTAssertEqual(subtracted.effectiveSeconds, 1200, "25 min moins 5 min d'inactivité")
        XCTAssertEqual(subtracted.outcome, .ranToTerm, "retrancher ne dégrade pas le résultat")
        XCTAssertEqual(subtracted.subtractedIdleSeconds, 300)

        let streak = await machine.streak
        XCTAssertEqual(streak, 1, "un retranchement ne casse pas la série")
    }

    /// L'utilisateur peut conserver la durée : l'inactivité est alors oubliée.
    func testKeepingIdleLeavesTheDurationIntact() async throws {
        var settings = SessionSettings()
        settings.idleDetectionInPomodoro = true
        let (machine, time, _) = makeMachine(settings: settings)

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        time.advance(by: .seconds(600))
        await machine.handle(.idleDetected(seconds: 300))
        guard case .finished(let session, _) = await beat(machine, time, for: 900) else {
            return XCTFail("session non close")
        }

        let kept = session.keepingIdle()
        XCTAssertEqual(kept.effectiveSeconds, 1500)
        XCTAssertEqual(kept.subtractedIdleSeconds, 0)
        XCTAssertEqual(kept.pendingIdleSeconds, 0, "l'arbitrage est tranché")
    }

    /// FR-024 — désactivée par défaut en Pomodoro : on ne retranche pas le temps
    /// de quelqu'un qui lit un document sans toucher au clavier.
    func testIdleDetectionIsOffByDefaultInPomodoro() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))
        await beat(machine, time, for: 600)
        await machine.handle(.idleDetected(seconds: 300))

        guard case .finished(let session, _) = await beat(machine, time, for: 900) else {
            return XCTFail("session non close")
        }
        XCTAssertEqual(session.pendingIdleSeconds, 0, "l'inactivité est ignorée en Pomodoro")
        XCTAssertEqual(session.effectiveSeconds, 1500)
    }

    /// FR-024 — activée par défaut en Tracker, où l'oubli d'arrêter est fréquent.
    func testIdleDetectionIsOnByDefaultInTracker() async throws {
        let (machine, time, _) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(600))
        await machine.handle(.idleDetected(seconds: 300))
        time.advance(by: .seconds(300))

        guard case .finished(let session, _) = await machine.handle(.stopByUser) else {
            return XCTFail("session non close")
        }
        XCTAssertEqual(session.pendingIdleSeconds, 300)
    }

    // MARK: - T077 : restauration après arrêt inopiné

    /// US5.6 — un pomodoro retrouvé est clôturé « Écourté », daté du dernier
    /// battement connu : c'est le dernier instant où l'on sait que l'app vivait.
    func testRestoredPomodoroIsClosedAtLastHeartbeat() async throws {
        let persistence = RecordingSessionPersistence()
        let started = Date(timeIntervalSince1970: 1_000_000)
        let heartbeat = started.addingTimeInterval(700)
        await persistence.save(SessionSnapshot(localID: UUID(), taskPageID: task, mode: .pomodoro,
                                               targetSeconds: 1500, startedAt: started,
                                               state: .running, completedPomodoroStreak: 2,
                                               lastHeartbeatAt: heartbeat))

        let (machine, _, _) = makeMachine(persistence: persistence)
        let restored = await machine.restoreSession()

        guard case .closed(let session) = restored else {
            return XCTFail("attendu une clôture, obtenu \(restored)")
        }
        XCTAssertEqual(session.outcome, .shortened)
        XCTAssertEqual(session.shortenReason, .unexpectedQuit)
        XCTAssertEqual(session.endedAt, heartbeat)
        XCTAssertEqual(session.effectiveSeconds, 700)
        let streak = await machine.streak
        XCTAssertEqual(streak, 0, "un arrêt inopiné casse la série")
    }

    /// US5.6 — un Tracker retrouvé est présenté **en pause** : l'utilisateur
    /// décide de reprendre ou d'arrêter, on ne tranche pas à sa place.
    func testRestoredTrackerIsPresentedPaused() async throws {
        let persistence = RecordingSessionPersistence()
        let started = Date(timeIntervalSince1970: 1_000_000)
        await persistence.save(SessionSnapshot(localID: UUID(), taskPageID: task, mode: .tracker,
                                               targetSeconds: nil, startedAt: started,
                                               state: .running, completedPomodoroStreak: 0,
                                               lastHeartbeatAt: started.addingTimeInterval(600)))

        let (machine, _, _) = makeMachine(persistence: persistence)
        let restored = await machine.restoreSession()

        guard case .paused(let snapshot) = restored else {
            return XCTFail("attendu une pause, obtenu \(restored)")
        }
        XCTAssertEqual(snapshot.state, .paused)
        let current = await machine.snapshot
        XCTAssertNotNil(current, "la session reste disponible")
    }

    /// Une session retrouvée de moins d'une minute ne produit rien (FR-023).
    func testRestoredSessionUnderAMinuteIsDropped() async throws {
        let persistence = RecordingSessionPersistence()
        let started = Date(timeIntervalSince1970: 1_000_000)
        await persistence.save(SessionSnapshot(localID: UUID(), taskPageID: task, mode: .pomodoro,
                                               targetSeconds: 1500, startedAt: started,
                                               state: .running, completedPomodoroStreak: 0,
                                               lastHeartbeatAt: started.addingTimeInterval(30)))

        let (machine, _, _) = makeMachine(persistence: persistence)
        let restored = await machine.restoreSession()

        XCTAssertEqual(restored, .nothing)
    }

    /// Une pause de repos retrouvée est simplement oubliée : elle n'a jamais
    /// produit d'entrée et n'a rien à restaurer.
    func testRestoredBreakIsDiscarded() async throws {
        let persistence = RecordingSessionPersistence()
        let started = Date(timeIntervalSince1970: 1_000_000)
        await persistence.save(SessionSnapshot(localID: UUID(), taskPageID: "", mode: .pomodoro,
                                               targetSeconds: 300, startedAt: started,
                                               state: .running, completedPomodoroStreak: 1,
                                               lastHeartbeatAt: started.addingTimeInterval(120),
                                               isBreak: true))

        let (machine, _, _) = makeMachine(persistence: persistence)
        let restored = await machine.restoreSession()

        XCTAssertEqual(restored, .nothing)
        let current = await machine.snapshot
        XCTAssertNil(current)
    }
}

/// Filet de sécurité indépendant des notifications système.
///
/// Fermer le clapet avec un écran externe ne met pas le Mac en veille ; une
/// notification peut aussi manquer, arriver trop tard, ou l'application être
/// suspendue par le système sans qu'aucune veille n'ait lieu. Dans tous ces cas
/// le seul témoin est l'horloge : entre deux ticks censés se suivre à la
/// seconde, un écart de plusieurs minutes prouve que le processus n'a pas tourné.
final class ClockJumpTests: XCTestCase {

    private let task = "task-page-1"

    private func makeMachine() -> (SessionMachine, VirtualTimeSource) {
        let time = VirtualTimeSource()
        return (SessionMachine(time: time, persistence: RecordingSessionPersistence(),
                               settings: SessionSettings()), time)
    }

    /// Un suivi libre survit au saut, mais le temps non travaillé en est retiré :
    /// c'est exactement ce qu'une veille détectée aurait produit.
    func testTrackerExcludesTheSuspendedTimeAndKeepsRunning() async throws {
        let (machine, time) = makeMachine()
        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))

        await beat(machine, time, for: 120)      // 2 min réellement travaillées
        time.advance(by: .seconds(600))          // le processus ne tourne pas
        let result = await machine.handle(.tick)

        XCTAssertEqual(result, SessionResult.none, "le suivi libre continue")
        let snapshot = await machine.snapshot
        XCTAssertEqual(snapshot?.state, .running)

        time.advance(by: .seconds(60))
        guard case .finished(let session, _) = await machine.handle(.stopByUser) else {
            return XCTFail("le suivi libre doit se clore normalement")
        }
        XCTAssertEqual(session.effectiveSeconds, 180,
                       "180 s travaillées, 600 s de suspension retirées")
    }

    /// Un pomodoro suspendu est clos **à l'instant du dernier tick connu** :
    /// dater la fin de maintenant compterait comme travaillé un temps qui ne
    /// l'a pas été.
    func testPomodoroIsClosedAtTheLastKnownTick() async throws {
        let (machine, time) = makeMachine()
        await machine.handle(.start(taskPageID: task, mode: .pomodoro, target: .seconds(1500)))

        await beat(machine, time, for: 300)
        let lastKnown = time.wallClock
        time.advance(by: .seconds(3600))
        let result = await machine.handle(.tick)

        guard case .finished(let session, let suggestion) = result else {
            return XCTFail("obtenu \(result)")
        }
        XCTAssertEqual(session.outcome, .shortened)
        XCTAssertEqual(session.shortenReason, .sleep)
        XCTAssertEqual(session.endedAt, lastKnown)
        XCTAssertEqual(session.effectiveSeconds, 300)
        XCTAssertNil(suggestion, "aucune pause proposée après un pomodoro écourté")
    }

    /// Une pause qui traverse une suspension est terminée : la reprendre au
    /// réveil ferait courir un décompte que personne n'a vu.
    func testBreakEndsAcrossASuspension() async throws {
        let (machine, time) = makeMachine()
        await machine.handle(.startBreak(.short(.seconds(300))))

        await beat(machine, time, for: 60)
        time.advance(by: .seconds(900))

        let afterJump = await machine.handle(.tick)
        XCTAssertEqual(afterJump, .breakEnded)
    }

    /// Le seuil ne doit pas se déclencher sur la gigue ordinaire : le journal
    /// réel montre des ticks à une ou deux secondes d'intervalle.
    func testOrdinaryJitterIsNotASuspension() async throws {
        let (machine, time) = makeMachine()
        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))

        for _ in 0..<10 {
            time.advance(by: .seconds(2))
            let tick = await machine.handle(.tick)
            XCTAssertEqual(tick, SessionResult.none)
        }

        await beat(machine, time, for: 60)
        guard case .finished(let session, _) = await machine.handle(.stopByUser) else {
            return XCTFail("obtenu autre chose qu'une clôture")
        }
        XCTAssertEqual(session.effectiveSeconds, 80, "aucune pause n'a été insérée")
    }

    /// Une session déjà en pause — veille détectée, puis saut constaté — ne doit
    /// pas empiler une seconde pause : le temps serait retranché deux fois.
    func testAPausedTrackerDoesNotAccumulateASecondPause() async throws {
        let (machine, time) = makeMachine()
        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        await beat(machine, time, for: 120)
        await machine.handle(.systemWillSleep)

        time.advance(by: .seconds(900))
        _ = await machine.handle(.tick)
        await machine.handle(.systemDidWake)

        time.advance(by: .seconds(60))
        guard case .finished(let session, _) = await machine.handle(.stopByUser) else {
            return XCTFail("obtenu autre chose qu'une clôture")
        }
        XCTAssertEqual(session.effectiveSeconds, 180)
        let snapshot = await machine.snapshot
        XCTAssertNil(snapshot)
    }
}
