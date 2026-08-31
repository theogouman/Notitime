import XCTest
import SwiftData
@testable import NotitimeCore

/// T098 — réglages : valeurs par défaut de US7.1, préréglages, persistance, et
/// effet du changement de valeurs terminées sur le filtre.
final class SettingsTests: XCTestCase {

    /// US7.1 — les valeurs par défaut doivent permettre d'utiliser
    /// l'application sans jamais ouvrir les réglages.
    func testDefaultsMatchTheSpecification() {
        let settings = AppSettings()

        XCTAssertEqual(settings.sessionDurations, [20, 30, 50])
        XCTAssertEqual(settings.shortBreakMinutes, 5)
        XCTAssertEqual(settings.longBreakMinutes, 15)
        XCTAssertEqual(settings.pomodorosBeforeLongBreak, 4)
        XCTAssertTrue(settings.idleDetectionEnabledTracker, "activée en Tracker")
        XCTAssertFalse(settings.idleDetectionEnabledPomodoro, "désactivée en Pomodoro")
        XCTAssertEqual(settings.idleThresholdMinutes, 5)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertTrue(settings.soundEnabled)
    }

    /// Les durées proposées sont remises d'aplomb avant d'être affichées : le
    /// magasin peut contenir n'importe quoi, l'écran de méthode non.
    func testSessionDurationsAreCleanedUp() {
        XCTAssertEqual(AppSettings(sessionMinutes: [50, 20, 30]).sessionDurations,
                       [20, 30, 50], "triées")
        XCTAssertEqual(AppSettings(sessionMinutes: [25, 25, 40]).sessionDurations,
                       [25, 40], "sans doublon")
        XCTAssertEqual(AppSettings(sessionMinutes: [0, 900]).sessionDurations,
                       [1, 180], "bornées")
        XCTAssertEqual(AppSettings(sessionMinutes: []).sessionDurations,
                       [20, 30, 50], "jamais vide")
    }

    /// Un préréglage personnalisé survit au redémarrage.
    func testCustomValuesPersist() throws {
        let container = try NotitimeStore.makeInMemoryContainer()
        let context = ModelContext(container)

        let settings = AppSettings(sessionMinutes: [15, 33], pomodorosBeforeLongBreak: 3)
        context.insert(settings)
        try context.save()

        let reloaded = try XCTUnwrap(try ModelContext(container)
            .fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(reloaded.sessionDurations, [15, 33])
        XCTAssertEqual(reloaded.pomodorosBeforeLongBreak, 3)
    }

    /// Les réglages pilotent la machine : changer une durée change la session.
    func testSettingsDriveTheSessionMachine() {
        let stored = AppSettings(sessionMinutes: [50, 80], shortBreakMinutes: 10,
                                 longBreakMinutes: 20, pomodorosBeforeLongBreak: 3,
                                 idleThresholdMinutes: 7)

        let session = stored.sessionSettings

        XCTAssertEqual(session.pomodoroSeconds, 3000)
        XCTAssertEqual(session.shortBreakSeconds, 600)
        XCTAssertEqual(session.longBreakSeconds, 1200)
        XCTAssertEqual(session.pomodorosBeforeLongBreak, 3)
        XCTAssertEqual(session.idleThresholdSeconds, 420)
    }

    /// US7.5 — changer les valeurs terminées change le filtre envoyé à Notion.
    func testDoneValuesFlowIntoTheTaskFilter() {
        let stored = AppSettings(onlyAssignedToMe: true, doneStatusValues: ["Livré", "Abandonné"])

        let filter = stored.taskFilterSettings(currentUserID: "u-9")

        XCTAssertEqual(filter.doneStatusValues, ["Livré", "Abandonné"])
        XCTAssertTrue(filter.onlyAssignedToMe)
        XCTAssertEqual(filter.currentUserID, "u-9")
    }

    /// Une durée aberrante est ramenée dans des bornes utilisables : un pomodoro
    /// de zéro minute se terminerait avant de commencer.
    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(AppSettings(sessionMinutes: [0]).sessionSettings.pomodoroSeconds, 60)
        XCTAssertEqual(AppSettings(pomodorosBeforeLongBreak: 0)
                        .sessionSettings.pomodorosBeforeLongBreak, 1)
        XCTAssertGreaterThan(AppSettings(idleThresholdMinutes: 0)
                        .sessionSettings.idleThresholdSeconds, 0)
    }
}
