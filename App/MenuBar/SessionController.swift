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
    @Published private(set) var tasks: [CachedTaskItem] = []
    /// Identifiants des tâches récentes, affichées en tête (FR-014).
    @Published private(set) var recentIDs: Set<String> = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var isLoadingTasks = false
    /// Message court affiché sous le menu : issue du dernier envoi, refus, etc.
    @Published private(set) var notice: String?
    @Published private(set) var pendingCount = 0
    @Published var selectedTaskID: String?
    /// Session close en attente d'arbitrage d'inactivité (FR-024).
    @Published private(set) var idleArbitration: CompletedSession?
    @Published private(set) var searchText: String = ""
    /// Entrées en échec définitif, consultables et réassignables (FR-030, FR-031).
    @Published private(set) var failedEntries: [OutboxEntry] = []
    /// Vrai pendant une session : `NotitimeApp` refuse alors de quitter sans
    /// confirmation (cas limite « quitter l'app volontairement »).
    var hasRunningSession: Bool { phase.offersStop }
    @Published private(set) var isTracker = false
    @Published private(set) var isPaused = false
    /// Temps écoulé, pour le suivi libre qui n'a pas de compte à rebours.
    @Published private(set) var elapsedLabel = "00:00"

    private let environment: AppEnvironment
    private let machine: SessionMachine
    private var ticker: Task<Void, Never>?
    /// Invalide un minuteur sans l'annuler : voir `stopTicking`.
    private var tickerGeneration = 0
    private var settings = SessionSettings()
    private let notifications: NotificationPresenter
    private var systemObserver: WorkspaceEventObserver?
    private var idleMonitor: EventInactivityMonitor?
    private var cache: TaskCache?
    private var drainTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

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

    /// Relit les réglages persistés et les propage. Appelé au démarrage et à
    /// chaque modification : un réglage qui n'aurait d'effet qu'au prochain
    /// lancement passerait pour inopérant.
    func applySettings() async {
        let context = environment.container.mainContext
        let stored = (try? context.fetch(FetchDescriptor<AppSettings>()).first)
            ?? {
                let created = AppSettings()
                context.insert(created)
                try? context.save()
                return created
            }()

        settings = stored.sessionSettings
        notifications.soundEnabled = stored.soundEnabled
        await machine.update(settings: settings)
        let userID = (try? context.fetch(FetchDescriptor<NotionConnection>()).first)?.ownerUserID
        await cache?.update(settings: stored.taskFilterSettings(currentUserID: userID))
        scheduleRefresh(everyMinutes: stored.taskRefreshIntervalMinutes)
    }

    /// FR-009, SC-006 — rafraîchissement périodique, **suspendu au repos** :
    /// une application de barre de menus ne doit rien émettre quand elle ne
    /// sert pas.
    private func scheduleRefresh(everyMinutes minutes: Int) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(1, minutes) * 60))
                guard let self, !Task.isCancelled else { return }
                // Au repos et sans session : on saute le tour.
                guard self.menuIsOpen || self.phase.offersStop else { continue }
                await self.loadTasks()
            }
        }
    }

    /// Le menu ouvert est le signal qu'une interaction est en cours.
    var menuIsOpen = false

    /// FR-015 — sans tâche, aucune session. Le menu doit donc pouvoir en offrir.
    func loadTasks() async {
        guard let binding = binding(for: .tasks) else {
            notice = "La base Tâches n'est pas encore liée. Ouvrez les réglages."
            return
        }
        isLoadingTasks = true
        defer { isLoadingTasks = false }

        do {
            let userID = (try? environment.container.mainContext
                .fetch(FetchDescriptor<NotionConnection>()).first)?.ownerUserID
            let stored = try? environment.container.mainContext
                .fetch(FetchDescriptor<AppSettings>()).first
            let filters = (stored ?? AppSettings()).taskFilterSettings(currentUserID: userID)

            let cache = self.cache ?? TaskCache(client: environment.notion,
                                                mapper: PropertyMapper(map: binding.propertyRefs),
                                                dataSourceID: binding.dataSourceID,
                                                settings: filters,
                                                log: environment.log)
            self.cache = cache
            await cache.update(settings: filters)
            try await cache.refresh()

            let all = await cache.search(searchText)
            let recents = await cache.recentTasks()
            tasks = recents + all.filter { item in !recents.contains { $0.id == item.id } }
            recentIDs = Set(recents.map(\.id))
            lastSync = await cache.lastSuccessfulSync
            notice = tasks.isEmpty ? emptyTaskMessage(filters) : nil
            if selectedTaskID == nil { selectedTaskID = tasks.first?.id }
        } catch {
            await environment.log.log(.error, "chargement des tâches en échec : \(error)")
            // FR-015a — le cache reste utilisable, et l'utilisateur sait de
            // quand datent les tâches affichées.
            let stamp = lastSync.map { SessionController.timeFormatter.string(from: $0) }
            notice = stamp.map { "Notion est injoignable. Tâches synchronisées à \($0)." }
                ?? "Notion est injoignable et aucune synchronisation n'a encore abouti."
        }
    }

    /// FR-015a — une liste vide s'explique, avec l'action correspondante.
    private func emptyTaskMessage(_ filters: TaskFilterSettings) -> String {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Aucune tâche ne correspond à cette recherche."
        }
        if filters.currentUserID != nil && !filters.includeUnassigned {
            return "Aucune tâche non terminée ne vous est assignée. "
                 + "Activez « tâches non assignées » dans les réglages."
        }
        return "Aucune tâche non terminée dans la base liée."
    }

    /// Recherche locale : aucune requête réseau (FR-013).
    func search(_ text: String) async {
        searchText = text
        guard let cache else { return }
        let all = await cache.search(text)
        let recents = await cache.recentTasks()
        let visible = text.trimmingCharacters(in: .whitespaces).isEmpty
            ? recents + all.filter { item in !recents.contains { $0.id == item.id } }
            : all
        tasks = visible
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Session

    func startPomodoro(minutes: Int? = nil) async {
        guard isConnected else { return refuseWithoutConnection() }
        guard let taskID = selectedTaskID, !taskID.isEmpty else {
            notice = "Choisissez d'abord une tâche."
            return
        }
        suggestedBreak = nil
        await cache?.noteUse(of: taskID)
        // FR-034 — le mode Concentration est un confort : son échec ne doit
        // jamais retarder ni empêcher le démarrage du chronomètre.
        let shortcut = (try? environment.container.mainContext
            .fetch(FetchDescriptor<AppSettings>()).first)?.focusShortcutName
        await FocusModeService.run(shortcutNamed: shortcut, log: environment.log)
        let target = Duration.seconds((minutes ?? settings.pomodoroSeconds / 60) * 60)
        let result = await machine.handle(.start(taskPageID: taskID, mode: .pomodoro, target: target))
        await react(to: result)
        startTicking()
    }

    /// US4.1 — suivi libre : aucune cible, l'utilisateur arrête quand il veut.
    func startTracker() async {
        guard isConnected else { return refuseWithoutConnection() }
        guard let taskID = selectedTaskID, !taskID.isEmpty else {
            notice = "Choisissez d'abord une tâche."
            return
        }
        suggestedBreak = nil
        await cache?.noteUse(of: taskID)
        await react(to: await machine.handle(.start(taskPageID: taskID, mode: .tracker,
                                                    target: nil)))
        startTicking()
        startIdleMonitoring()
    }

    /// US4.1 — pause et reprise, réservées au Tracker (FR-021).
    func togglePause() async {
        guard let snapshot = await machine.snapshot else { return }
        await react(to: await machine.handle(snapshot.state == .paused ? .resume : .pause))
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

    /// US5.6 — traite la session retrouvée selon son mode, puis met en place
    /// les observateurs système.
    func restore() async {
        installSystemObservers()

        switch await machine.restoreSession() {
        case .nothing:
            break
        case .closed(let session):
            // Un pomodoro interrompu par un arrêt inopiné produit quand même son
            // entrée : le temps a bien été travaillé (principe IV).
            notice = "Session précédente retrouvée et clôturée."
            await handleCompletion(session)
        case .paused:
            notice = "Suivi libre retrouvé, en pause. Reprenez ou arrêtez."
            startTicking()
        }
        await refreshPhase()
    }

    private func installSystemObservers() {
        guard systemObserver == nil else { return }
        systemObserver = WorkspaceEventObserver(
            log: environment.log,
            onSleep: { [weak self] in await self?.react(to: await self?.machine.handle(.systemWillSleep) ?? .none) },
            onWake: { [weak self] in await self?.react(to: await self?.machine.handle(.systemDidWake) ?? .none) }
        )
        systemObserver?.start()
    }

    private func startIdleMonitoring() {
        idleMonitor?.stop()
        idleMonitor = EventInactivityMonitor(thresholdSeconds: settings.idleThresholdSeconds) {
            [weak self] seconds in
            await self?.machine.handle(.idleDetected(seconds: seconds))
        }
        idleMonitor?.start()
    }

    /// Un tick par seconde : c'est la granularité de l'affichage, et la machine
    /// n'a besoin de rien de plus fin — la durée se calcule sur l'horloge, pas
    /// sur le nombre de ticks reçus.
    /// Invalide le minuteur courant **sans annuler aucune tâche**.
    ///
    /// Le minuteur appelle `react`, qui déclenche l'envoi : annuler la tâche
    /// depuis l'intérieur reviendrait à s'annuler soi-même, et `URLSession`
    /// abandonnerait la requête. On invalide donc par génération — la boucle
    /// constate au tour suivant qu'elle n'est plus la courante et sort.
    private func stopTicking() {
        tickerGeneration &+= 1
    }

    /// Un tick par seconde : c'est la granularité de l'affichage, et la machine
    /// n'a besoin de rien de plus fin — la durée se calcule sur l'horloge, pas
    /// sur le nombre de ticks reçus.
    private func startTicking() {
        tickerGeneration &+= 1
        let generation = tickerGeneration
        ticker = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.tickerGeneration == generation else { return }
                let result = await self.machine.handle(.tick)
                await self.react(to: result)
                // Sortie sur constat, jamais sur annulation : `react` a pu
                // déclencher un envoi qui doit aller à son terme.
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
            stopTicking()
            await refreshPhase()

        case .breakEnded:
            suggestedBreak = nil
            notice = "Pause terminée."
            stopTicking()
            await refreshPhase()
            if notificationsAllowed { await notifications.breakFinished(isLong: false) }

        case .finished(let session, let suggestion):
            // Le minuteur s'annulait lui-même ici, puis l'envoi partait depuis
            // la tâche annulée : `URLSession` l'abandonnait aussitôt. On détache
            // l'arrêt du minuteur de la suite du traitement.
            stopTicking()
            await refreshPhase()
            // FR-032 : prévenir d'abord, envoyer ensuite. L'utilisateur n'a pas
            // à attendre que Notion réponde pour savoir que son pomodoro est fini.
            if session.outcome == .ranToTerm, notificationsAllowed {
                await notifications.pomodoroFinished(
                    taskTitle: title(of: session.taskPageID),
                    minutes: EntryComposer.minutes(session.effectiveSeconds))
            }
            await handleCompletion(session)
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
    /// FR-024 — une inactivité détectée se tranche **avant** la mise en file :
    /// on ne devine pas si l'utilisateur lisait ou s'était absenté.
    private func handleCompletion(_ session: CompletedSession) async {
        idleMonitor?.stop()
        guard session.pendingIdleSeconds > 0 else {
            await deliver(session)
            return
        }
        idleArbitration = session
        notice = "\(EntryComposer.minutes(session.pendingIdleSeconds)) min d'inactivité "
               + "détectées. Les conserver ou les retrancher ?"
    }

    func resolveIdle(subtract: Bool) async {
        guard let session = idleArbitration else { return }
        idleArbitration = nil
        let resolved = subtract ? session.subtractingIdle() : session.keepingIdle()
        await environment.log.log(.session, "inactivité \(subtract ? "retranchée" : "conservée")"
                                  + " durée finale=\(resolved.effectiveSeconds)s")
        await deliver(resolved)
    }

    /// FR-032 — notifications et son sont désactivables.
    private var notificationsAllowed: Bool {
        let stored = try? environment.container.mainContext
            .fetch(FetchDescriptor<AppSettings>()).first
        return stored?.notificationsEnabled ?? true
    }

    private func refreshPhase() async {
        if let snapshot = await machine.snapshot {
            isTracker = snapshot.mode == .tracker && !snapshot.isBreak
            isPaused = snapshot.state == .paused
            let paused = snapshot.pauseIntervals.reduce(0.0) { total, interval in
                total + max(0, min(interval.end, environment.time.wallClock)
                    .timeIntervalSince(interval.start))
            }
            let worked = max(0, environment.time.wallClock
                .timeIntervalSince(snapshot.startedAt) - paused)
            elapsedLabel = SessionControls.format(.seconds(worked))
        } else {
            isTracker = false
            isPaused = false
            elapsedLabel = "00:00"
        }
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
        switch await outbox.sendDetached(entry) {
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
        if pendingCount > 0 { await drainOnce() }
    }

    /// Un compte Notion est relié. Les liaisons, elles, survivent à une
    /// déconnexion : les prendre pour une configuration valide laissait démarrer
    /// une session qui n'aurait eu nulle part où aller.
    private var isConnected: Bool {
        let context = environment.container.mainContext
        return ((try? context.fetch(FetchDescriptor<NotionConnection>()))?.isEmpty == false)
    }

    private func refuseWithoutConnection() {
        notice = "Connectez votre compte Notion avant de démarrer une session."
    }

    private func makeComposer(_ binding: DatabaseBinding) -> EntryComposer? {
        let context = environment.container.mainContext
        guard let connection = try? context.fetch(FetchDescriptor<NotionConnection>()).first else {
            notice = "Aucune connexion Notion active."
            return nil
        }
        let mapper = PropertyMapper(map: binding.propertyRefs)
        let titles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        let composer = EntryComposer(mapper: mapper,
                                     dataSourceID: binding.dataSourceID,
                                     personUserID: connection.ownerUserID,
                                     usesDefaultTemplate: binding.usesDefaultTemplate,
                                     taskTitleLookup: { titles[$0] })
        // Une entrée écrite sans statut doit être explicable : c'est que les
        // options de la base ne savent pas exprimer ce résultat.
        let unexpressible = composer.unexpressibleOutcomes()
        if !unexpressible.isEmpty {
            let names = unexpressible.map(\.rawValue).joined(separator: ", ")
            let options = mapper.reference(.entryStatus)?.options.joined(separator: ", ") ?? ""
            Task { [log = environment.log] in
                await log.log(.sync, "statut non exprimable pour \(names) — "
                              + "options de la base : \(options)")
            }
        }
        return composer
    }

    // MARK: - Drain de la file (US6)

    /// Rejoue les entrées en attente, dans l'ordre chronologique, en respectant
    /// l'issue de leur tentative précédente. Ne s'arrête jamais sur une erreur
    /// transitoire : c'est la garantie du principe IV.
    func drainOutbox() async {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            defer { Task { @MainActor in self?.drainTask = nil } }
            await self?.drainOnce()
        }
        await drainTask?.value
    }

    private func drainOnce() async {
        let context = environment.container.mainContext
        let pending = SendState.pending.rawValue
        guard let stored = try? context.fetch(
            FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.sendStateRaw == pending })
        ), !stored.isEmpty else { return }

        guard let binding = binding(for: .timeEntries), let composer = makeComposer(binding) else {
            return
        }
        let outbox = Outbox(client: environment.notion, composer: composer, log: environment.log)

        for entry in stored.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let next = entry.nextAttemptAt, next > Date() { continue }

            let composed = ComposedEntry(localID: entry.localID, taskPageID: entry.taskPageID,
                                         title: entry.title, startedAt: entry.startedAt,
                                         endedAt: entry.endedAt,
                                         durationMinutes: entry.durationMinutes,
                                         mode: entry.mode,
                                         outcome: SessionOutcome(rawValue: entry.outcomeRaw) ?? .ranToTerm,
                                         shortenReason: entry.shortenReasonRaw
                                            .flatMap(ShortenReason.init(rawValue:)),
                                         subtractedIdleMinutes: entry.subtractedIdleMinutes)
            let previous = AttemptOutcome(rawValue: entry.attemptOutcomeRaw) ?? .neverAttempted

            switch await outbox.sendDetached(composed, afterAttempt: previous) {
            case .sent:
                markSent(entry.localID)
            case .failedPermanently(let cause):
                markFailed(entry.localID, cause: cause)
            case .retryLater(let outcome, let cause):
                markRetry(entry.localID, attemptOutcome: outcome, cause: cause)
            }
        }
        refreshPendingCount()
    }

    /// FR-031 — réassigner une entrée en échec à une autre tâche avant renvoi.
    func reassign(_ localID: UUID, to taskPageID: String) async {
        update(localID) {
            $0.taskPageID = taskPageID
            $0.sendStateRaw = SendState.pending.rawValue
            $0.failureCause = nil
            // La tentative repart de zéro : la page n'a jamais existé.
            $0.attemptOutcomeRaw = AttemptOutcome.neverAttempted.rawValue
            $0.nextAttemptAt = nil
        }
        await environment.log.log(.sync, "entrée réassignée=\(localID) tâche=\(taskPageID)")
        refreshPendingCount()
        await drainOutbox()
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
            // FR-029 — backoff plafonné : l'entrée n'est jamais abandonnée,
            // seulement différée.
            let delay = Outbox.retryDelay(forAttempt: $0.attemptCount)
            $0.nextAttemptAt = Date().addingTimeInterval(delay.seconds)
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
        let failed = SendState.failedPermanently.rawValue
        failedEntries = (try? context.fetch(
            FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.sendStateRaw == failed })
        )) ?? []
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
