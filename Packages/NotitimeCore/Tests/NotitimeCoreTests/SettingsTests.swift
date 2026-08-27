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

        XCTAssertEqual(settings.pomodoroMinutes, 25)
        XCTAssertEqual(settings.shortBreakMinutes, 5)
        XCTAssertEqual(settings.longBreakMinutes, 15)
        XCTAssertEqual(settings.pomodorosBeforeLongBreak, 4)
        XCTAssertTrue(settings.idleDetectionEnabledTracker, "activée en Tracker")
        XCTAssertFalse(settings.idleDetectionEnabledPomodoro, "désactivée en Pomodoro")
        XCTAssertEqual(settings.idleThresholdMinutes, 5)
        XCTAssertTrue(settings.notificationsEnabled)
        XCTAssertTrue(settings.soundEnabled)
    }

    /// US7.2 — les deux préréglages de FR-018.
    func testPresetsMatchTheSpecification() {
        XCTAssertEqual(PomodoroPreset.classic.pomodoroMinutes, 25)
        XCTAssertEqual(PomodoroPreset.classic.shortBreakMinutes, 5)
        XCTAssertEqual(PomodoroPreset.classic.longBreakMinutes, 15)

        XCTAssertEqual(PomodoroPreset.extended.pomodoroMinutes, 50)
        XCTAssertEqual(PomodoroPreset.extended.shortBreakMinutes, 10)
        XCTAssertEqual(PomodoroPreset.extended.longBreakMinutes, 20)
    }

    /// Un préréglage personnalisé survit au redémarrage.
    func testCustomValuesPersist() throws {
        let container = try NotitimeStore.makeInMemoryContainer()
        let context = ModelContext(container)

        let settings = AppSettings(pomodoroMinutes: 33, pomodorosBeforeLongBreak: 3)
        context.insert(settings)
        try context.save()

        let reloaded = try XCTUnwrap(try ModelContext(container)
            .fetch(FetchDescriptor<AppSettings>()).first)
        XCTAssertEqual(reloaded.pomodoroMinutes, 33)
        XCTAssertEqual(reloaded.pomodorosBeforeLongBreak, 3)
    }

    /// Les réglages pilotent la machine : changer une durée change la session.
    func testSettingsDriveTheSessionMachine() {
        let stored = AppSettings(pomodoroMinutes: 50, shortBreakMinutes: 10,
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
        let stored = AppSettings(showUnassignedTasks: true, doneStatusValues: ["Livré", "Abandonné"])

        let filter = stored.taskFilterSettings(currentUserID: "u-9")

        XCTAssertEqual(filter.doneStatusValues, ["Livré", "Abandonné"])
        XCTAssertTrue(filter.includeUnassigned)
        XCTAssertEqual(filter.currentUserID, "u-9")
    }

    /// Une durée aberrante est ramenée dans des bornes utilisables : un pomodoro
    /// de zéro minute se terminerait avant de commencer.
    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(AppSettings(pomodoroMinutes: 0).sessionSettings.pomodoroSeconds, 60)
        XCTAssertEqual(AppSettings(pomodorosBeforeLongBreak: 0)
                        .sessionSettings.pomodorosBeforeLongBreak, 1)
        XCTAssertGreaterThan(AppSettings(idleThresholdMinutes: 0)
                        .sessionSettings.idleThresholdSeconds, 0)
    }
}
