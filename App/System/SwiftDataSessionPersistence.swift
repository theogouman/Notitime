import Foundation
import SwiftData
import NotitimeCore

/// Persistance de la session courante sur SwiftData (FR-022).
///
/// Un acteur dédié plutôt que le `mainContext` : la machine à états écrit à
/// chaque transition, y compris depuis un tick de fond, et ces écritures ne
/// doivent pas dépendre de la disponibilité du fil principal.
actor SwiftDataSessionPersistence: SessionPersistence {

    private let container: ModelContainer
    private var context: ModelContext?

    init(container: ModelContainer) {
        self.container = container
    }

    private func makeContext() -> ModelContext {
        if let context { return context }
        let created = ModelContext(container)
        context = created
        return created
    }

    func save(_ snapshot: SessionSnapshot?) async {
        let context = makeContext()
        // Une seule session active à la fois (FR-017) : on remplace plutôt que
        // d'accumuler, faute de quoi une restauration ne saurait laquelle lire.
        try? context.delete(model: ActiveSession.self)

        if let snapshot {
            context.insert(ActiveSession(localID: snapshot.localID,
                                         taskPageID: snapshot.taskPageID,
                                         mode: snapshot.mode,
                                         targetSeconds: snapshot.targetSeconds,
                                         startedAt: snapshot.startedAt,
                                         state: snapshot.state,
                                         pauseIntervals: snapshot.pauseIntervals,
                                         idleIntervals: snapshot.idleIntervals,
                                         completedPomodoroStreak: snapshot.completedPomodoroStreak,
                                         lastHeartbeatAt: snapshot.lastHeartbeatAt))
        }
        try? context.save()
    }

    func load() async -> SessionSnapshot? {
        let context = makeContext()
        guard let stored = try? context.fetch(FetchDescriptor<ActiveSession>()).first else {
            return nil
        }
        return SessionSnapshot(localID: stored.localID,
                               taskPageID: stored.taskPageID,
                               mode: stored.mode,
                               targetSeconds: stored.targetSeconds,
                               startedAt: stored.startedAt,
                               state: SessionRunState(rawValue: stored.stateRaw) ?? .running,
                               pauseIntervals: stored.pauseIntervals,
                               idleIntervals: stored.idleIntervals,
                               completedPomodoroStreak: stored.completedPomodoroStreak,
                               lastHeartbeatAt: stored.lastHeartbeatAt)
    }
}
