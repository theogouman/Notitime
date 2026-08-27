import Foundation
import SwiftData
import NotitimeCore

/// Orchestration d'une session côté interface : chargement des tâches, machine
/// à états, composition puis envoi de l'entrée.
///
/// Tout ce qui relève de la décision vit dans `NotitimeCore` ; ce contrôleur ne
/// fait que relier la machine à l'écran et au réseau.
@MainActor
final class SessionController: ObservableObject {

    @Published private(set) var phase: SessionPhase = .idle
    /// Pause proposée, en attente de décision. Distincte d'une pause en cours :
    /// tant qu'elle n'est pas acceptée, la machine ne tient aucune session.
    private var suggestedBreak: BreakKind?
    @Published private(set) var tasks: [FetchedTask] = []
    @Published private(set) var isLoadingTasks = false
    /// Message court affiché sous le menu : issue du dernier envoi, refus, etc.
    @Published private(set) var notice: String?
    @Published private(set) var pendingCount = 0
    @Published var selectedTaskID: String?

    private let environment: AppEnvironment
    private let machine: SessionMachine
    private var ticker: Task<Void, Never>?
    private var settings = SessionSettings()
    private let notifications: NotificationPresenter

    init(environment: AppEnvironment) {
        self.environment = environment
        self.notifications = NotificationPresenter(log: environment.log)
        self.machine = SessionMachine(
            time: environment.time,
            persistence: SwiftDataSessionPersistence(container: environment.container),
            settings: SessionSettings(),
            log: environment.log
        )
    }

    // MARK: - Tâches

    /// FR-015 — sans tâche, aucune session. Le menu doit donc pouvoir en offrir.
    func loadTasks() async {
        guard let binding = binding(for: .tasks) else {
            notice = "La base Tâches n'est pas encore liée. Ouvrez les réglages."
            return
        }
        isLoadingTasks = true
        defer { isLoadingTasks = false }

        do {
            let fetch = TaskFetch(client: environment.notion,
                                  mapper: PropertyMapper(map: binding.propertyRefs),
                                  log: environment.log)
            tasks = try await fetch.load(from: binding.dataSourceID)
            notice = tasks.isEmpty ? "Aucune tâche dans la base liée." : nil
            if selectedTaskID == nil { selectedTaskID = tasks.first?.id }
        } catch {
            await environment.log.log(.error, "chargement des tâches en échec : \(error)")
            notice = "Notion est injoignable. Les tâches affichées datent de la dernière synchronisation."
        }
    }

    // MARK: - Session

    func startPomodoro(minutes: Int? = nil) async {
        guard let taskID = selectedTaskID, !taskID.isEmpty else {
            notice = "Choisissez d'abord une tâche."
            return
        }
        suggestedBreak = nil
        let target = Duration.seconds((minutes ?? settings.pomodoroSeconds / 60) * 60)
        let result = await machine.handle(.start(taskPageID: taskID, mode: .pomodoro, target: target))
        await react(to: result)
        startTicking()
    }

    func stop() async {
        // La vue ne propose plus d'arrêter hors session ; cette garde couvre la
        // course entre un pomodoro qui se termine seul et un clic simultané.
        guard phase.offersStop else {
            suggestedBreak = nil
            await refreshPhase()
            return
        }
        await react(to: await machine.handle(.stopByUser))
    }

    /// L'utilisateur décline la pause proposée.
    func dismissBreak() async {
        suggestedBreak = nil
        await refreshPhase()
    }

    func startBreak(_ kind: BreakKind) async {
        suggestedBreak = nil
        await react(to: await machine.handle(.startBreak(kind)))
        startTicking()
    }

    func restore() async {
        await machine.restore()
        await refreshPhase()
        if await machine.snapshot != nil { startTicking() }
    }

    /// Un tick par seconde : c'est la granularité de l'affichage, et la machine
    /// n'a besoin de rien de plus fin — la durée se calcule sur l'horloge, pas
    /// sur le nombre de ticks reçus.
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let result = await self.machine.handle(.tick)
                await self.react(to: result)
                if await self.machine.snapshot == nil { return }
            }
        }
    }

    private func react(to result: SessionResult) async {
        switch result {
        case .none:
            await refreshPhase()

        case .refused(let reason):
            notice = SessionController.message(for: reason)

        case .ignored(let seconds):
            // FR-023 : l'utilisateur doit savoir pourquoi rien n'est parti.
            notice = "Session de \(seconds) s ignorée : moins d'une minute, rien n'a été envoyé."
            ticker?.cancel()
            await refreshPhase()

        case .breakEnded:
            suggestedBreak = nil
            notice = "Pause terminée."
            ticker?.cancel()
            await refreshPhase()
            await notifications.breakFinished(isLong: false)

        case .finished(let session, let suggestion):
            ticker?.cancel()
            await refreshPhase()
            // FR-032 : prévenir d'abord, envoyer ensuite. L'utilisateur n'a pas
            // à attendre que Notion réponde pour savoir que son pomodoro est fini.
            if session.outcome == .ranToTerm {
                await notifications.pomodoroFinished(
                    taskTitle: title(of: session.taskPageID),
                    minutes: EntryComposer.minutes(session.effectiveSeconds))
            }
            await deliver(session)
            suggestedBreak = suggestion
            await refreshPhase()
            if let suggestion {
                notice = suggestion.isLong ? "Pomodoro terminé. Pause longue proposée."
                                           : "Pomodoro terminé. Pause courte proposée."
            }
        }
    }

    /// Unique point de mise à jour de la phase : elle se **dérive** de l'état de
    /// la machine et n'est jamais posée à la main.
    private func refreshPhase() async {
        phase = SessionPhase.derive(snapshot: await machine.snapshot,
                                    suggestedBreak: suggestedBreak,
                                    now: environment.time.wallClock)
    }

    // MARK: - Envoi

    /// Compose l'entrée, la met en file, puis tente l'envoi. La file est la
    /// source de vérité : rien n'est retiré avant confirmation (FR-027).
    private func deliver(_ session: CompletedSession) async {
        guard let binding = binding(for: .timeEntries) else {
            notice = "La base Time Entries n'est pas liée : l'entrée n'a pas pu être composée."
            return
        }
        guard let composer = makeComposer(binding) else { return }

        let entry = composer.compose(session)
        persist(entry)
        await environment.log.log(.sync, "entrée mise en file=\(entry.localID) "
                                  + "tâche=\(entry.taskPageID) durée=\(entry.durationMinutes)min")
        refreshPendingCount()

        let outbox = Outbox(client: environment.notion, composer: composer, log: environment.log)
        switch await outbox.send(entry) {
        case .sent(let pageID):
            await environment.log.log(.sync, "entrée retirée de la file page=\(pageID)")
            markSent(entry.localID)
            notice = "Entrée de \(entry.durationMinutes) min envoyée dans Notion."
        case .failedPermanently(let cause):
            markFailed(entry.localID, cause: cause)
            await environment.log.log(.error, "entrée en échec définitif=\(entry.localID), "
                                      + "conservée en file pour réassignation")
            notice = "Notion a refusé l'entrée : \(cause)"
        case .retryLater(let attemptOutcome, let cause):
            markRetry(entry.localID, attemptOutcome: attemptOutcome, cause: cause)
            await environment.log.log(.sync, "entrée laissée en file=\(entry.localID) "
                                      + "tentatives=\(attemptCount(of: entry.localID))")
            notice = "Entrée en attente : \(cause)"
        }
        refreshPendingCount()
    }

    private func makeComposer(_ binding: DatabaseBinding) -> EntryComposer? {
        let context = environment.container.mainContext
        guard let connection = try? context.fetch(FetchDescriptor<NotionConnection>()).first else {
            notice = "Aucune connexion Notion active."
            return nil
        }
        let mapper = PropertyMapper(map: binding.propertyRefs)
        let titles = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })

        return EntryComposer(mapper: mapper,
                             dataSourceID: binding.dataSourceID,
                             personUserID: connection.ownerUserID,
                             // Les options réelles du statut : un `status`
                             // n'accepte rien d'autre (FR-026).
                             statusOptions: mapper.reference(.entryStatus)?.options ?? [],
                             taskTitleLookup: { titles[$0] })
    }

    // MARK: - File d'envoi

    private func persist(_ entry: ComposedEntry) {
        let context = environment.container.mainContext
        context.insert(OutboxEntry(localID: entry.localID,
                                   taskPageID: entry.taskPageID,
                                   title: entry.title,
                                   startedAt: entry.startedAt,
                                   endedAt: entry.endedAt,
                                   durationMinutes: entry.durationMinutes,
                                   mode: entry.mode,
                                   outcome: entry.outcome,
                                   shortenReason: entry.shortenReason,
                                   subtractedIdleMinutes: entry.subtractedIdleMinutes))
        try? context.save()
    }

    private func update(_ localID: UUID, _ mutate: (OutboxEntry) -> Void) {
        let context = environment.container.mainContext
        let stored = try? context.fetch(
            FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.localID == localID })
        ).first
        guard let stored else { return }
        mutate(stored)
        try? context.save()
    }

    /// FR-027 — la confirmation retire l'entrée de la file. Il n'existe pas
    /// d'état « envoyée » : ce qui reste en file est précisément ce qui n'est pas
    /// encore arrivé dans Notion.
    private func markSent(_ localID: UUID) {
        let context = environment.container.mainContext
        try? context.delete(model: OutboxEntry.self,
                            where: #Predicate { $0.localID == localID })
        try? context.save()
    }

    private func markFailed(_ localID: UUID, cause: String) {
        update(localID) {
            $0.sendStateRaw = SendState.failedPermanently.rawValue
            $0.failureCause = cause
            $0.attemptOutcomeRaw = AttemptOutcome.explicitError.rawValue
            $0.attemptCount += 1
        }
    }

    private func markRetry(_ localID: UUID, attemptOutcome: AttemptOutcome, cause: String) {
        update(localID) {
            $0.sendStateRaw = SendState.pending.rawValue
            $0.failureCause = cause
            $0.attemptOutcomeRaw = attemptOutcome.rawValue
            $0.attemptCount += 1
        }
    }

    private func attemptCount(of localID: UUID) -> Int {
        let context = environment.container.mainContext
        return (try? context.fetch(
            FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.localID == localID })
        ).first?.attemptCount) ?? 0
    }

    private func refreshPendingCount() {
        let context = environment.container.mainContext
        let pending = SendState.pending.rawValue
        pendingCount = (try? context.fetchCount(
            FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.sendStateRaw == pending })
        )) ?? 0
    }

    // MARK: - Utilitaires

    private func binding(for role: DatabaseRole) -> DatabaseBinding? {
        let raw = role.rawValue
        return try? environment.container.mainContext.fetch(
            FetchDescriptor<DatabaseBinding>(predicate: #Predicate { $0.roleRaw == raw })
        ).first
    }

    func title(of pageID: String) -> String {
        tasks.first { $0.id == pageID }?.title ?? "Tâche"
    }

    private static func message(for reason: RefusalReason) -> String {
        switch reason {
        case .noTaskSelected: return "Choisissez d'abord une tâche."
        case .alreadyRunning: return "Une session est déjà en cours."
        case .pauseUnavailableInPomodoro: return "Un pomodoro ne se met pas en pause."
        case .nothingRunning: return "Aucune session en cours."
        }
    }
}

extension DatabaseBinding {
    /// Mapping typé, tel que `PropertyMapper` l'attend.
    var propertyRefs: [PropertyKey: PropertyRef] {
        Dictionary(uniqueKeysWithValues: propertyMap.compactMap { key, value in
            PropertyKey(rawValue: key).map { ($0, value) }
        })
    }
}

extension BreakKind {
    var isLong: Bool { if case .long = self { return true }; return false }
}
