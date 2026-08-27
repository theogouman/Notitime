import XCTest
@testable import NotitimeCore

/// T078 — SC-005 : l'écart entre durée enregistrée et durée réellement
/// travaillée reste sous 2 secondes, dans les deux modes, pauses et inactivité
/// retranchée comprises.
final class DurationAccuracyTests: XCTestCase {

    private static let tolerance = 2

    private func machine(_ time: VirtualTimeSource,
                         settings: SessionSettings = SessionSettings()) -> SessionMachine {
        SessionMachine(time: time, persistence: RecordingSessionPersistence(), settings: settings)
    }

    /// Un pomodoro haché de ticks irréguliers reste exact à la seconde près.
    func testPomodoroStaysAccurateAcrossIrregularTicks() async throws {
        let time = VirtualTimeSource()
        let machine = machine(time)

        await machine.handle(.start(taskPageID: "t", mode: .pomodoro, target: .seconds(1500)))
        // Ticks irréguliers : la machine se fie à l'horloge, pas à leur nombre.
        var elapsed = 0
        while elapsed < 1500 {
            let step = [1, 3, 7, 2].randomElement() ?? 1
            time.advance(by: .seconds(step))
            elapsed += step
            if case .finished(let session, _) = await machine.handle(.tick) {
                XCTAssertLessThanOrEqual(abs(session.effectiveSeconds - 1500),
                                         DurationAccuracyTests.tolerance)
                return
            }
        }
        XCTFail("le pomodoro aurait dû se clore")
    }

    /// Un suivi libre entrecoupé de pauses : la durée enregistrée est la somme
    /// des périodes réellement travaillées.
    func testTrackerAccuracyWithManyPauses() async throws {
        let time = VirtualTimeSource()
        let machine = machine(time)
        var worked = 0

        await machine.handle(.start(taskPageID: "t", mode: .tracker, target: nil))
        for index in 1...12 {
            let work = 30 + index * 5
            time.advance(by: .seconds(work))
            worked += work
            await machine.handle(.pause)
            time.advance(by: .seconds(20 + index))
            await machine.handle(.resume)
        }
        time.advance(by: .seconds(45))
        worked += 45

        guard case .finished(let session, _) = await machine.handle(.stopByUser) else {
            return XCTFail("session non close")
        }
        XCTAssertLessThanOrEqual(abs(session.effectiveSeconds - worked),
                                 DurationAccuracyTests.tolerance,
                                 "enregistré \(session.effectiveSeconds), travaillé \(worked)")
    }

    /// Pauses **et** inactivité retranchée sur la même session.
    func testTrackerAccuracyWithPausesAndSubtractedIdle() async throws {
        let time = VirtualTimeSource()
        let machine = machine(time)

        await machine.handle(.start(taskPageID: "t", mode: .tracker, target: nil))
        time.advance(by: .seconds(300))
        await machine.handle(.pause)
        time.advance(by: .seconds(120))          // pause : exclue
        await machine.handle(.resume)
        time.advance(by: .seconds(600))
        await machine.handle(.idleDetected(seconds: 240))   // inactivité : arbitrée
        time.advance(by: .seconds(60))

        guard case .finished(let session, _) = await machine.handle(.stopByUser) else {
            return XCTFail("session non close")
        }
        let final = session.subtractingIdle()
        // 300 + 600 + 60 travaillées, moins 240 d'inactivité = 720
        XCTAssertLessThanOrEqual(abs(final.effectiveSeconds - 720),
                                 DurationAccuracyTests.tolerance,
                                 "obtenu \(final.effectiveSeconds)")
    }

    /// La durée envoyée à Notion, en minutes, ne dérive pas non plus.
    func testMinuteRoundingStaysWithinTolerance() {
        for seconds in [60, 90, 300, 1500, 3600, 5423] {
            let minutes = EntryComposer.minutes(seconds)
            let drift = abs(minutes * 60 - seconds)
            XCTAssertLessThanOrEqual(drift, 30, "\(seconds) s → \(minutes) min")
        }
    }
}
