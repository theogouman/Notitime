import XCTest
@testable import NotitimeCore

/// La pause en cours : celle qui n'est pas encore refermée.
///
/// Les tests existants mettaient toujours en pause **puis reprenaient** avant
/// d'arrêter : l'intervalle était donc toujours clos quand on comptait. Une
/// pause ouverte, elle, était notée avec une durée nulle — le compteur tournait
/// pendant la pause, et le temps mis de côté partait dans Notion.
final class SessionPauseTests: XCTestCase {

    private func machine(_ time: VirtualTimeSource) -> SessionMachine {
        SessionMachine(time: time, persistence: RecordingSessionPersistence(),
                       settings: SessionSettings())
    }

    func testWorkedTimeStopsWhilePaused() async throws {
        let time = VirtualTimeSource()
        let machine = machine(time)

        await machine.handle(.start(taskPageID: "t", mode: .tracker, target: nil))
        time.advance(by: .seconds(60))
        await machine.handle(.pause)
        time.advance(by: .seconds(90))

        let current = await machine.snapshot
        let snapshot = try XCTUnwrap(current)
        let now = time.wallClock
        let worked = now.timeIntervalSince(snapshot.startedAt)
            - snapshot.pausedSeconds(until: now)
        XCTAssertEqual(worked, 60, accuracy: 1, "le compteur a tourné pendant la pause")
        XCTAssertEqual(snapshot.pausedSeconds(until: now), 90, accuracy: 1)
    }

    /// Arrêter sans reprendre : la pause ouverte doit être retranchée elle aussi.
    func testStoppingWhilePausedExcludesTheOpenPause() async {
        let time = VirtualTimeSource()
        let machine = machine(time)

        await machine.handle(.start(taskPageID: "t", mode: .tracker, target: nil))
        time.advance(by: .seconds(300))
        await machine.handle(.pause)
        time.advance(by: .seconds(120))

        guard case .finished(let session, _) = await machine.handle(.stopByUser) else {
            return XCTFail("session non close")
        }
        XCTAssertLessThanOrEqual(abs(session.effectiveSeconds - 300), 1,
                                 "les 120 s de pause ouverte sont parties dans l'entrée")
    }

    func testPausedSinceIsTheStartOfTheCurrentPause() async throws {
        let time = VirtualTimeSource()
        let machine = machine(time)

        await machine.handle(.start(taskPageID: "t", mode: .tracker, target: nil))
        let started = await machine.snapshot
        let running = try XCTUnwrap(started)
        XCTAssertNil(running.pausedSince, "une session qui tourne n'est en pause depuis rien")

        time.advance(by: .seconds(30))
        let pausedAt = time.wallClock
        await machine.handle(.pause)
        time.advance(by: .seconds(45))

        let afterPause = await machine.snapshot
        let paused = try XCTUnwrap(afterPause)
        let since = try XCTUnwrap(paused.pausedSince)
        XCTAssertEqual(since.timeIntervalSince(pausedAt), 0, accuracy: 1)

        await machine.handle(.resume)
        let afterResume = await machine.snapshot
        let resumed = try XCTUnwrap(afterResume)
        XCTAssertNil(resumed.pausedSince)
    }

    /// Une pause refermée reste comptée comme avant : la correction ne devait
    /// rien changer au cas nominal.
    func testClosedPausesAreUnchanged() async throws {
        let time = VirtualTimeSource()
        let machine = machine(time)

        await machine.handle(.start(taskPageID: "t", mode: .tracker, target: nil))
        time.advance(by: .seconds(100))
        await machine.handle(.pause)
        time.advance(by: .seconds(50))
        await machine.handle(.resume)
        time.advance(by: .seconds(100))

        let closed = await machine.snapshot
        let snapshot = try XCTUnwrap(closed)
        XCTAssertEqual(snapshot.pausedSeconds(until: time.wallClock), 50, accuracy: 1)
    }
}
