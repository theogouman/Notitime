import XCTest
@testable import NotitimeCore

/// T070 — mode Tracker : durée libre, pause, reprise, arrêt (FR-021).
final class TrackerMachineTests: XCTestCase {

    private let task = "task-page-1"

    private func makeMachine() -> (SessionMachine, VirtualTimeSource) {
        let time = VirtualTimeSource()
        return (SessionMachine(time: time, persistence: RecordingSessionPersistence()), time)
    }

    /// US4.3, US4.5 — l'arrêt d'un suivi libre est **normal** : la session est
    /// allée à son terme, elle n'est pas écourtée. C'est l'utilisateur qui
    /// décide de sa durée, il n'y a pas de cible à manquer.
    func testStoppingATrackerCompletesRatherThanShortens() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(600))
        let result = await machine.handle(.stopByUser)

        guard case .finished(let session, let suggestion) = result else {
            return XCTFail("attendu terminé, obtenu \(result)")
        }
        XCTAssertEqual(session.outcome, .ranToTerm)
        XCTAssertEqual(session.mode, .tracker)
        XCTAssertEqual(session.effectiveSeconds, 600)
        XCTAssertNil(suggestion, "le Tracker ne propose pas de pause pomodoro")
    }

    /// US4.2 — les pauses sont exclues de la durée enregistrée.
    func testPausedTimeIsExcludedFromTheDuration() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(120))          // 2 min travaillées
        await machine.handle(.pause)
        time.advance(by: .seconds(60))           // 1 min en pause
        await machine.handle(.resume)
        time.advance(by: .seconds(60))           // 1 min travaillée
        let result = await machine.handle(.stopByUser)

        guard case .finished(let session, _) = result else {
            return XCTFail("attendu terminé, obtenu \(result)")
        }
        XCTAssertEqual(session.effectiveSeconds, 180, "3 min travaillées sur 4 écoulées")
    }

    /// Plusieurs pauses successives se cumulent toutes.
    func testSeveralPausesAccumulate() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        for _ in 1...3 {
            time.advance(by: .seconds(60))
            await machine.handle(.pause)
            time.advance(by: .seconds(30))
            await machine.handle(.resume)
        }
        let result = await machine.handle(.stopByUser)

        guard case .finished(let session, _) = result else {
            return XCTFail("obtenu \(result)")
        }
        XCTAssertEqual(session.effectiveSeconds, 180, "90 s de pause retranchées de 270 s")
    }

    /// FR-023 — la règle des 60 secondes vaut aussi pour le Tracker, et porte
    /// sur la durée **effective**, pauses déduites.
    func testTrackerUnderSixtyEffectiveSecondsIsIgnored() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(50))
        await machine.handle(.pause)
        time.advance(by: .seconds(600))          // longue pause : ne compte pas
        await machine.handle(.resume)
        let result = await machine.handle(.stopByUser)

        XCTAssertEqual(result, .ignored(effectiveSeconds: 50))
    }

    /// FR-021 — une mise en veille met le Tracker en pause, elle ne le clôt pas.
    func testSleepPausesTheTrackerWithoutClosingIt() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(300))
        let result = await machine.handle(.systemWillSleep)

        XCTAssertEqual(result, .none, "aucune entrée n'est produite par une veille")
        let snapshot = await machine.snapshot
        XCTAssertEqual(snapshot?.state, .paused)
        XCTAssertNotNil(snapshot, "la session survit à la veille")
    }

    /// Le réveil reprend le décompte là où il s'était arrêté.
    func testWakeResumesTheTracker() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(120))
        await machine.handle(.systemWillSleep)
        time.advance(by: .seconds(3600))         // une heure de veille
        await machine.handle(.systemDidWake)
        time.advance(by: .seconds(60))
        let result = await machine.handle(.stopByUser)

        guard case .finished(let session, _) = result else {
            return XCTFail("obtenu \(result)")
        }
        XCTAssertEqual(session.effectiveSeconds, 180, "l'heure de veille ne compte pas")
    }

    /// Le Tracker n'a pas de compte à rebours : un tick ne le clôt jamais.
    func testTicksNeverEndATracker() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        for _ in 1...10 {
            let result = await beat(machine, time, for: 600)
            XCTAssertEqual(result, .none)
        }

        let snapshot = await machine.snapshot
        XCTAssertNotNil(snapshot, "seul un arrêt explicite termine un suivi libre")
    }

    /// FR-021 — pause et reprise sont disponibles, contrairement au Pomodoro.
    func testTrackerAcceptsManualPause() async throws {
        let (machine, time) = makeMachine()

        await machine.handle(.start(taskPageID: task, mode: .tracker, target: nil))
        time.advance(by: .seconds(60))
        let result = await machine.handle(.pause)

        XCTAssertEqual(result, .none)
        let snapshot = await machine.snapshot
        XCTAssertEqual(snapshot?.state, .paused)
    }
}
