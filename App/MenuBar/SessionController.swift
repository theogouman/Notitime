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
    /// Une création est en cours : la ligne en cours d'écriture attend Notion.
    @Published private(set) var isCreatingTask = false
    /// Les projets, les plus récemment actifs en tête (voir `ProjectDirectory`).
    @Published private(set) var projects: [ProjectSummary] = []
    /// Identifiants des tâches récentes, affichées en tête (FR-014).
    @Published private(set) var recentIDs: Set<String> = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var isLoadingTasks = false
    /// La dernière annonce faite à l'utilisateur : issue d'un envoi, refus,
    /// session retrouvée. Elle vit hors du panneau, le temps d'être lue.
    @Published private(set) var toast: Toast?
    /// Ce que la liste de tâches a à dire d'elle-même quand elle est vide ou
    /// périmée. C'est un **état**, pas un événement : il reste tant qu'il est
    /// vrai, et n'a donc rien à faire dans une annonce fugitive.
    @Published private(set) var taskListMessage: String?

    /// Une annonce, et rien de plus : un texte, et une identité qui change à
    /// chaque fois pour que deux annonces identiques se distinguent.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    /// Annonce un fait à l'utilisateur. Ce qui est annoncé disparaît de
    /// lui-même : rien de ce qui passe ici ne doit rester à l'écran.
    private func announce(_ text: String) {
        toast = Toast(text: text)
    }
    @Published private(set) var pendingCount = 0
    @Published var selectedTaskID: String?
    /// Tâche dépliée dans le lanceur — le panneau de méthode est ouvert.
    ///
    /// Elle vivait dans la vue ; c'est la taille de la fenêtre qui l'en a sortie :
    /// le panneau se règle sur l'écran affiché, et il ne peut pas deviner l'état
    /// interne d'une de ses sous-vues.
    @Published var expandedTaskID: String?
    /// Session close en attente d'arbitrage d'inactivité (FR-024).
    @Published private(set) var idleArbitration: CompletedSession?
    /// Session qui vient de produire une entrée, tant que l'écran de fin n'a pas
    /// été quitté (US4, US6, FR-026, FR-030).
    @Published private(set) var completion: SessionCompletion?
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
    /// Depuis combien de temps la session est en pause, `nil` si elle tourne.
    @Published private(set) var pausedLabel: String?
    /// Durée visée par la session en cours, nulle en suivi libre : c'est elle
    /// qui donne au cadran la part d'arc à remplir.
    @Published private(set) var targetSeconds: Int?
    /// Heure d'échéance, calculée depuis le départ et non depuis l'instant
    /// présent : recalculée à chaque tick, elle sautillerait d'une seconde.
    @Published private(set) var endsAt: Date?
    /// Titres des projets, par identifiant de page.
    ///
    /// Le cache de tâches ne retient que l'identifiant du projet : afficher
    /// celui-ci sous une tâche n'apprendrait rien. Les titres sont donc lus une
    /// fois par lancement, depuis la base Projets déjà liée.
    @Published private(set) var projectNames: [String: String] = [:]

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
    /// La prochaine remise d'entrée doit-elle ouvrir l'écran de fin ? Posé par
    /// `handleCompletion`, lu par `deliver` — l'arbitrage d'inactivité passe
    /// entre les deux (FR-024).
    private var confirmsCompletion = true
    /// L'écran de fin doit survivre à la prochaine fermeture du panneau.
    private var completionHeld = false
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

    /// Crée une tâche dans Notion depuis le menu, et la place en tête de liste.
    ///
    /// La liste ne se recharge pas pour l'accueillir : un rafraîchissement
    /// complet coûterait une seconde et ferait clignoter tout ce qui est
    /// affiché, alors qu'on sait exactement ce qui vient de naître.
    @discardableResult
    func createTask(titled title: String,
                    projectPageID: String? = nil,
                    due: Date? = nil) async -> CachedTaskItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let cache else {
            announce("La base Tâches n'est pas encore liée. Ouvrez les réglages.")
            return nil
        }
        isCreatingTask = true
        defer { isCreatingTask = false }
        do {
            let created = try await cache.createTask(titled: trimmed,
                                                     projectPageID: projectPageID,
                                                     due: due)
            tasks.removeAll { $0.id == created.id }
            tasks.insert(created, at: 0)
            // Elle est prête à être lancée : c'est ce pour quoi on vient de
            // l'écrire.
            selectedTaskID = created.id
            return created
        } catch {
            await environment.log.log(.error, "création de tâche en échec : \(error)")
            announce("La tâche n'a pas pu être créée dans Notion.")
            return nil
        }
    }

    /// Charge les projets pour la ligne en cours d'écriture.
    ///
    /// À la demande, et une seule fois : la liste n'est utile qu'au moment de
    /// rattacher une tâche, et une requête à chaque ouverture du menu coûterait
    /// le quota pour une information qui bouge peu.
    func loadProjects() async {
        guard projects.isEmpty, let binding = binding(for: .projects) else { return }
        let directory = ProjectDirectory(client: environment.notion,
                                         mapper: PropertyMapper(map: binding.propertyRefs),
                                         log: environment.log)
        do {
            projects = try await directory.load(from: binding.dataSourceID)
            // Les noms servent aussi à la liste des tâches : autant les tenir
            // du même chargement.
            for project in projects where projectNames[project.id] == nil {
                projectNames[project.id] = project.name
            }
        } catch {
            // Le projet est un complément : son absence ne doit jamais empêcher
            // d'écrire une tâche.
            await environment.log.log(.error, "chargement des projets en échec : \(error)")
        }
    }

    /// FR-015 — sans tâche, aucune session. Le menu doit donc pouvoir en offrir.
    func loadTasks() async {
        guard let binding = binding(for: .tasks) else {
            announce("La base Tâches n'est pas encore liée. Ouvrez les réglages.")
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
            // La liaison peut avoir changé depuis la construction du cache :
            // réglages, reconnexion, revalidation. Sans ce rappel, le cache
            // interrogeait l'ancienne base jusqu'à la fin du processus.
            await cache.rebind(dataSourceID: binding.dataSourceID,
                               mapper: PropertyMapper(map: binding.propertyRefs))
            await cache.update(settings: filters)
            try await cache.refresh()

            let all = await cache.search(searchText)
            let recents = await cache.recentTasks()
            tasks = recents + all.filter { item in !recents.contains { $0.id == item.id } }
            recentIDs = Set(recents.map(\.id))
            lastSync = await cache.lastSuccessfulSync
            taskListMessage = tasks.isEmpty ? emptyTaskMessage(filters) : nil
            if selectedTaskID == nil { selectedTaskID = tasks.first?.id }
            await loadProjectNames()
        } catch {
            await environment.log.log(.error, "chargement des tâches en échec : \(error)")
            // FR-015a — le cache reste utilisable, et l'utilisateur sait de
            // quand datent les tâches affichées.
            let stamp = lastSync.map { SessionController.timeFormatter.string(from: $0) }
            taskListMessage = stamp.map { "Notion est injoignable. Tâches synchronisées à \($0)." }
                ?? "Notion est injoignable et aucune synchronisation n'a encore abouti."
        }
    }

    /// Titres des projets liés, lus une seule fois : ils changent rarement, et
    /// une requête à chaque rafraîchissement des tâches coûterait le quota pour
    /// une information stable. Un échec est silencieux — le projet n'est qu'un
    /// complément d'affichage, il ne doit jamais empêcher de choisir une tâche.
    private func loadProjectNames() async {
        guard projectNames.isEmpty, let binding = binding(for: .projects) else { return }
        let mapper = PropertyMapper(map: binding.propertyRefs)
        var names: [String: String] = [:]
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            guard let page = try? await environment.notion.queryDataSource(binding.dataSourceID,
                                                                          body: body) else { return }
            for project in page.results {
                if let title = mapper.readTitle(.projectTitle, from: project.properties) {
                    names[project.id] = title
                }
            }
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil
        projectNames = names
    }

    /// Nom du projet d'une tâche, quand il est connu.
    func projectName(of task: CachedTaskItem) -> String? {
        task.projectPageID.flatMap { projectNames[$0] }
    }

    // MARK: - Méthodes de lancement (FR-016, FR-018)

    /// Durées proposées : les deux préréglages de FR-018, plus la durée
    /// personnalisée des réglages si elle en diffère.
    var pomodoroPresets: [Int] {
        let standard = PomodoroPreset.allCases.map(\.pomodoroMinutes)
        let custom = storedSettings?.pomodoroMinutes
        guard let custom, !standard.contains(custom) else { return standard }
        return (standard + [custom]).sorted()
    }

    /// Dernière méthode lancée.
    ///
    /// Plus aucune surface ne la met en avant : arriver sur le panneau avec un
    /// choix déjà fait n'est pas ce qu'on attend d'un panneau de choix. Elle
    /// reste enregistrée, elle ne décide plus de rien.
    var lastMethod: (mode: SessionMode, minutes: Int?)? {
        guard let raw = storedSettings?.lastMethodRaw,
              let mode = SessionMode(rawValue: raw) else { return nil }
        return (mode, storedSettings?.lastMethodMinutes)
    }

    private var storedSettings: AppSettings? {
        try? environment.container.mainContext.fetch(FetchDescriptor<AppSettings>()).first
    }

    private func rememberMethod(_ mode: SessionMode, minutes: Int?) {
        guard let stored = storedSettings else { return }
        stored.lastMethodRaw = mode.rawValue
        stored.lastMethodMinutes = minutes
        try? environment.container.mainContext.save()
    }

    /// FR-015a — une liste vide s'explique, avec l'action correspondante.
    private func emptyTaskMessage(_ filters: TaskFilterSettings) -> String {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Aucune tâche ne correspond à cette recherche."
        }
        if filters.onlyAssignedToMe {
            return "Aucune tâche non terminée ne vous est assignée. Décochez "
                 + "« n'afficher que mes tâches » dans les réglages pour voir toute la base."
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

    /// L'écran affiché est-il la liste des tâches ?
    ///
    /// C'est le seul écran qui a besoin de place : tous les autres tiennent dans
    /// un panneau étroit (voir `RootView.listSize` et `compactSize`).
    var showsTaskList: Bool {
        guard case .idle = phase else { return false }
        return completion == nil && idleArbitration == nil && expandedTaskID == nil
    }

    // MARK: - Fin de session (US4, US6)

    /// Ce qu'il reste à dire d'une session qui vient de se terminer : ce qu'elle
    /// a duré, sur quoi, et où en est son entrée.
    ///
    /// Elle ne vit que le temps du panneau ouvert : rien n'en est persisté, et
    /// la file reste seule source de vérité sur l'envoi (FR-027).
    struct SessionCompletion: Equatable {

        /// L'entrée correspondante dans la file — c'est par lui que l'écran
        /// apprend qu'un envoi différé a fini par aboutir.
        let localID: UUID
        let taskPageID: String
        let taskTitle: String
        let minutes: Int
        let mode: SessionMode
        var delivery: Delivery

        /// Où en est l'entrée. `sent` porte l'adresse de la page créée, quand
        /// l'identifiant rendu par l'envoi permet de la former.
        enum Delivery: Equatable {
            case sending
            case sent(URL?)
            case pending

            /// Une identité par état : c'est elle qui déclenche la transition
            /// d'un texte à l'autre.
            var id: String {
                switch self {
                case .sending: return "sending"
                case .sent: return "sent"
                case .pending: return "pending"
                }
            }
        }
    }

    /// L'adresse d'une page à partir de son identifiant.
    ///
    /// L'envoi rend l'identifiant de la page créée, pas son adresse : Notion
    /// accepte l'identifiant nu dans une URL et redirige vers la page.
    static func pageURL(_ pageID: String) -> URL? {
        let identifier = pageID.replacingOccurrences(of: "-", with: "")
        guard !identifier.isEmpty else { return nil }
        return URL(string: "https://www.notion.so/\(identifier)")
    }

    /// Quitte l'écran de fin. Aucun effet de bord : l'entrée suit son cours.
    func dismissCompletion() {
        completion = nil
        completionHeld = false
    }

    /// Retient l'écran de fin par-dessus la prochaine fermeture du panneau.
    ///
    /// Ouvrir l'entrée dans Notion fait passer le premier plan au navigateur, ce
    /// qui referme le panneau — au retour, l'écran avait disparu et le menu
    /// affichait la liste, comme si la session n'avait jamais eu lieu. Partir
    /// **consulter** ce qu'on vient d'enregistrer n'est pas en avoir fini.
    func holdCompletion() {
        completionHeld = true
    }

    /// Le panneau vient de se refermer : l'écran de fin s'en va avec lui, sauf
    /// s'il a été retenu — auquel cas il ne l'est plus que cette fois-là.
    func panelDidClose() {
        guard completion != nil else { return }
        if completionHeld { completionHeld = false } else { dismissCompletion() }
    }

    /// « J'ai terminé ma tâche » : le statut passe à « terminé » dans Notion, la
    /// tâche quitte la liste, et l'écran de fin rend la main.
    ///
    /// L'écriture n'est pas mise en file : contrairement à une entrée de temps,
    /// une tâche cochée par erreur se décoche dans Notion, et rien n'est perdu
    /// si l'appel échoue — on le dit, et la tâche reste ouverte.
    func finishTask() async {
        guard let completion else { return }
        let pageID = completion.taskPageID
        dismissCompletion()
        guard let cache else {
            return announce("La base Tâches n'est pas encore liée. Ouvrez les réglages.")
        }
        do {
            let value = try await cache.markDone(pageID)
            tasks.removeAll { $0.id == pageID }
            if selectedTaskID == pageID { selectedTaskID = tasks.first?.id }
            announce("Tâche marquée « \(value) » dans Notion")
        } catch let refusal as TaskCache.CompletionRefusal {
            await environment.log.log(.error, "tâche non marquée=\(pageID) : \(refusal)")
            announce("Cette base ne dit pas ce que veut dire « terminé » : "
                     + "renseigne un statut de fin dans les réglages")
        } catch {
            await environment.log.log(.error, "tâche non marquée=\(pageID) : \(error)")
            announce("La tâche n'a pas pu être marquée comme terminée dans Notion")
        }
    }

    /// Relance une session sur la même tâche, avec la dernière méthode retenue.
    func relaunch() async {
        guard let completion else { return }
        selectedTaskID = completion.taskPageID
        // À défaut de méthode mémorisée, celle qu'on vient d'employer : c'est
        // « relancer », pas « choisir ».
        let method = lastMethod ?? (mode: completion.mode, minutes: nil)
        expandedTaskID = nil
        dismissCompletion()
        switch method.mode {
        case .pomodoro: await startPomodoro(minutes: method.minutes)
        case .tracker: await startTracker()
        }
    }

    /// Fait passer l'écran de fin à l'état d'envoi suivant.
    private func setDelivery(_ delivery: SessionCompletion.Delivery, for localID: UUID) {
        guard completion?.localID == localID else { return }
        completion?.delivery = delivery
    }

    // MARK: - Session

    func startPomodoro(minutes: Int? = nil) async {
        guard isConnected else { return refuseWithoutConnection() }
        guard let taskID = selectedTaskID, !taskID.isEmpty else {
            announce("Tu dois d'abord sélectionner une tâche")
            return
        }
        suggestedBreak = nil
        await cache?.noteUse(of: taskID)
        await beginFocus()
        let chosen = minutes ?? settings.pomodoroSeconds / 60
        rememberMethod(.pomodoro, minutes: chosen)
        let target = Duration.seconds(chosen * 60)
        let result = await machine.handle(.start(taskPageID: taskID, mode: .pomodoro, target: target))
        await react(to: result)
        startTicking()
    }

    /// US4.1 — suivi libre : aucune cible, l'utilisateur arrête quand il veut.
    func startTracker() async {
        guard isConnected else { return refuseWithoutConnection() }
        guard let taskID = selectedTaskID, !taskID.isEmpty else {
            announce("Tu dois d'abord sélectionner une tâche")
            return
        }
        suggestedBreak = nil
        rememberMethod(.tracker, minutes: nil)
        await cache?.noteUse(of: taskID)
        // Le suivi libre est une session comme une autre : ce qui vaut pour le
        // pomodoro vaut pour lui.
        await beginFocus()
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

    // MARK: - Mode Concentration (FR-034)

    /// Demande à macOS d'entrer en Concentration, si l'option est active.
    ///
    /// Le mode Concentration est un confort : son échec ne doit jamais retarder
    /// ni empêcher le démarrage du chronomètre — c'est pourquoi `FocusModeService`
    /// n'attend pas la fin du raccourci et ne remonte rien.
    private func beginFocus() async {
        guard let settings = storedSettings, settings.focusModeEnabled else { return }
        await FocusModeService.run(shortcutNamed: settings.focusShortcutName,
                                   log: environment.log)
    }

    /// Rend la main à la fin de la session. Sans ce second raccourci, la
    /// concentration s'activerait sans jamais se désactiver.
    private func endFocus() async {
        guard let settings = storedSettings, settings.focusModeEnabled else { return }
        await FocusModeService.run(shortcutNamed: settings.focusEndShortcutName,
                                   log: environment.log)
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
            // entrée : le temps a bien été travaillé (principe IV). L'écran de
            // fin, lui, n'a pas lieu d'être : la session s'est achevée hors de
            // la vue de l'utilisateur, souvent des heures plus tôt.
            announce("Session précédente retrouvée et clôturée.")
            await handleCompletion(session, confirms: false)
        case .paused:
            announce("Suivi libre retrouvé, en pause. Reprenez ou arrêtez.")
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
            announce(SessionController.message(for: reason))

        case .ignored:
            // FR-023 : l'utilisateur doit savoir pourquoi rien n'est parti.
            announce("La session était trop courte, ça n'a pas été enregistré dans Notion")
            stopTicking()
            await endFocus()
            await refreshPhase()

        case .breakEnded:
            suggestedBreak = nil
            announce("La pause est terminée, on reprend ?")
            stopTicking()
            await refreshPhase()
            if notificationsAllowed { await notifications.breakFinished(isLong: false) }

        case .finished(let session, let suggestion):
            // Le minuteur s'annulait lui-même ici, puis l'envoi partait depuis
            // la tâche annulée : `URLSession` l'abandonnait aussitôt. On détache
            // l'arrêt du minuteur de la suite du traitement.
            stopTicking()
            // La concentration s'arrête avec la session, avant même que
            // l'entrée ne parte : rendre la main ne doit pas attendre Notion.
            await endFocus()
            await refreshPhase()
            // FR-032 : prévenir d'abord, envoyer ensuite. L'utilisateur n'a pas
            // à attendre que Notion réponde pour savoir que son pomodoro est fini.
            if session.outcome == .ranToTerm, notificationsAllowed {
                await notifications.pomodoroFinished(
                    taskTitle: title(of: session.taskPageID),
                    minutes: EntryComposer.minutes(session.effectiveSeconds))
            }
            // L'écran de fin est réservé aux arrêts qui produisent une entrée
            // sans autre suite : un pomodoro allé à son terme a déjà le sien,
            // qui propose la pause (FR-020).
            await handleCompletion(session,
                                   confirms: !(session.mode == .pomodoro
                                               && session.outcome == .ranToTerm))
            suggestedBreak = suggestion
            await refreshPhase()
            // Une pause proposée signe un pomodoro allé au bout : c'est le seul
            // cas où l'on félicite, et la durée dit ce qui a été tenu.
            if suggestion != nil {
                announce("Bravo, les \(EntryComposer.minutes(session.effectiveSeconds)) min "
                         + "de pomodoro sont atteints")
            }
        }
    }

    /// Unique point de mise à jour de la phase : elle se **dérive** de l'état de
    /// la machine et n'est jamais posée à la main.
    /// FR-024 — une inactivité détectée se tranche **avant** la mise en file :
    /// on ne devine pas si l'utilisateur lisait ou s'était absenté.
    private func handleCompletion(_ session: CompletedSession,
                                  confirms: Bool = true) async {
        idleMonitor?.stop()
        confirmsCompletion = confirms
        guard session.pendingIdleSeconds > 0 else {
            await deliver(session)
            return
        }
        // L'arbitrage a son propre écran, avec ses deux boutons : le redire en
        // annonce laissait un message sans fin de vie dans tous les écrans.
        idleArbitration = session
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
            let now = environment.time.wallClock
            let worked = max(0, now.timeIntervalSince(snapshot.startedAt)
                             - snapshot.pausedSeconds(until: now))
            elapsedLabel = SessionControls.format(.seconds(worked))
            // Indicatif, et rien d'autre : cette durée ne part pas dans Notion,
            // elle dit seulement depuis combien de temps on s'est arrêté.
            pausedLabel = snapshot.pausedSince.map { since in
                SessionControls.format(.seconds(max(0, now.timeIntervalSince(since))))
            }
            targetSeconds = snapshot.targetSeconds
            endsAt = snapshot.targetSeconds.map {
                snapshot.startedAt.addingTimeInterval(Double($0))
            }
        } else {
            isTracker = false
            isPaused = false
            elapsedLabel = "00:00"
            pausedLabel = nil
            targetSeconds = nil
            endsAt = nil
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
            announce("La base Time Entries n'est pas liée : l'entrée n'a pas pu être composée.")
            return
        }
        guard let composer = makeComposer(binding) else { return }

        let entry = composer.compose(session)
        let confirms = confirmsCompletion
        if confirms {
            completion = SessionCompletion(localID: entry.localID,
                                           taskPageID: session.taskPageID,
                                           taskTitle: title(of: session.taskPageID),
                                           minutes: entry.durationMinutes,
                                           mode: session.mode,
                                           delivery: .sending)
        }
        persist(entry)
        await environment.log.log(.sync, "entrée mise en file=\(entry.localID) "
                                  + "tâche=\(entry.taskPageID) durée=\(entry.durationMinutes)min "
                                  + "modèle=\(binding.usesDefaultTemplate ? "défaut" : "aucun")")
        refreshPendingCount()

        let outbox = Outbox(client: environment.notion, composer: composer, log: environment.log)
        switch await outbox.sendDetached(entry) {
        case .sent(let pageID):
            await environment.log.log(.sync, "entrée retirée de la file page=\(pageID)")
            markSent(entry.localID)
            setDelivery(.sent(SessionController.pageURL(pageID)), for: entry.localID)
            // L'écran de fin dit déjà ce qu'il est advenu de l'entrée : le
            // répéter en pied de panneau ferait deux fois la même annonce.
            if !confirms { announce("Entrée de \(entry.durationMinutes) min envoyée dans Notion.") }
        case .failedPermanently(let cause):
            markFailed(entry.localID, cause: cause)
            await environment.log.log(.error, "entrée en échec définitif=\(entry.localID), "
                                      + "conservée en file pour réassignation")
            setDelivery(.pending, for: entry.localID)
            if !confirms { announce("Notion a refusé l'entrée : \(cause)") }
        case .retryLater(let attemptOutcome, let cause):
            markRetry(entry.localID, attemptOutcome: attemptOutcome, cause: cause)
            await environment.log.log(.sync, "entrée laissée en file=\(entry.localID) "
                                      + "tentatives=\(attemptCount(of: entry.localID))")
            setDelivery(.pending, for: entry.localID)
            if !confirms { announce("Entrée en attente : \(cause)") }
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
        announce("Connectez votre compte Notion avant de démarrer une session.")
    }

    private func makeComposer(_ binding: DatabaseBinding) -> EntryComposer? {
        let context = environment.container.mainContext
        guard let connection = try? context.fetch(FetchDescriptor<NotionConnection>()).first else {
            announce("Aucune connexion Notion active.")
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
            case .sent(let pageID):
                markSent(entry.localID)
                // L'écran de fin peut être encore ouvert : une entrée partie
                // avec retard doit s'y voir arriver.
                setDelivery(.sent(SessionController.pageURL(pageID)), for: entry.localID)
            case .failedPermanently(let cause):
                markFailed(entry.localID, cause: cause)
                setDelivery(.pending, for: entry.localID)
            case .retryLater(let outcome, let cause):
                markRetry(entry.localID, attemptOutcome: outcome, cause: cause)
                setDelivery(.pending, for: entry.localID)
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
        case .noTaskSelected: return "Tu dois d'abord sélectionner une tâche"
        case .alreadyRunning: return "Une session est déjà en cours, impossible de cumuler"
        case .pauseUnavailableInPomodoro: return "Impossible de mettre en pause un pomodoro"
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
