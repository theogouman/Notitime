import XCTest
@testable import NotitimeCore

/// La phase affichée doit refléter ce que la machine tient réellement.
///
/// En production, la fin d'un pomodoro laissait le menu sur un état actif avec
/// son bouton d'arrêt, alors que plus aucune session ne tournait : les clics
/// étaient refusés en `nothingRunning`. Une pause **proposée** n'est pas une
/// pause **en cours**.
final class SessionPhaseTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-08-27T14:30:00Z")!

    private func snapshot(targetSeconds: Int?, isBreak: Bool = false,
                          startedSecondsAgo: Int = 0) -> SessionSnapshot {
        SessionSnapshot(localID: UUID(), taskPageID: "t-1", mode: .pomodoro,
                        targetSeconds: targetSeconds,
                        startedAt: now.addingTimeInterval(TimeInterval(-startedSecondsAgo)),
                        state: .running, completedPomodoroStreak: 0,
                        lastHeartbeatAt: now, isBreak: isBreak)
    }

    /// Le défaut observé : sans session, une pause proposée ne doit pas produire
    /// une phase qui offre de l'arrêter.
    func testSuggestedBreakIsNotAnActiveBreak() {
        let phase = SessionPhase.derive(snapshot: nil, suggestedBreak: .short(.seconds(300)), now: now)

        XCTAssertEqual(phase, .breakSuggested(.short(.seconds(300))))
        XCTAssertFalse(phase.offersStop,
                       "rien ne tourne : proposer d'arrêter mènerait à un refus")
    }

    /// Une pause réellement démarrée, elle, s'arrête.
    func testStartedBreakOffersToStop() {
        let phase = SessionPhase.derive(snapshot: snapshot(targetSeconds: 300, isBreak: true),
                                        suggestedBreak: nil, now: now)

        guard case .onBreak = phase else { return XCTFail("attendu pause en cours, obtenu \(phase)") }
        XCTAssertTrue(phase.offersStop)
    }

    func testRunningSessionOffersToStop() {
        let phase = SessionPhase.derive(snapshot: snapshot(targetSeconds: 1500, startedSecondsAgo: 300),
                                        suggestedBreak: nil, now: now)

        guard case .running(let remaining, _) = phase else {
            return XCTFail("attendu session en cours, obtenu \(phase)")
        }
        XCTAssertEqual(remaining, .seconds(1200))
        XCTAssertTrue(phase.offersStop)
    }

    /// Sans session ni proposition, le menu revient au repos.
    func testNoSessionMeansIdle() {
        XCTAssertEqual(SessionPhase.derive(snapshot: nil, suggestedBreak: nil, now: now), .idle)
        XCTAssertFalse(SessionPhase.idle.offersStop)
    }

    /// Un snapshot sans cible — le mode Tracker — n'affiche pas de compte à
    /// rebours, mais reste une session active.
    func testTrackerHasNoCountdownButStillRuns() {
        let phase = SessionPhase.derive(snapshot: snapshot(targetSeconds: nil), suggestedBreak: nil, now: now)

        guard case .running(let remaining, _) = phase else {
            return XCTFail("attendu session en cours, obtenu \(phase)")
        }
        XCTAssertNil(remaining)
        XCTAssertTrue(phase.offersStop)
    }

    /// La proposition ne survit pas au démarrage de la session suivante : c'est
    /// ce qui la faisait persister à l'écran.
    func testAStartedSessionOverridesAPendingSuggestion() {
        let phase = SessionPhase.derive(snapshot: snapshot(targetSeconds: 1500),
                                        suggestedBreak: .short(.seconds(300)), now: now)

        guard case .running = phase else { return XCTFail("obtenu \(phase)") }
    }
}
