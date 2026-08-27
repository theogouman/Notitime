import Foundation

/// Réglages de session. Valeurs par défaut de FR-018 : 25/5/15, pause longue
/// tous les quatre pomodoros.
public struct SessionSettings: Sendable, Equatable {
    public var pomodoroSeconds: Int = 25 * 60
    public var shortBreakSeconds: Int = 5 * 60
    public var longBreakSeconds: Int = 15 * 60
    public var pomodorosBeforeLongBreak: Int = 4
    /// FR-024 — seuil d'inactivité, et activation **par mode**.
    ///
    /// Désactivée en Pomodoro par défaut : lire un document sans toucher au
    /// clavier reste du travail, et la durée y est bornée par la cible. Activée
    /// en Tracker, où l'oubli d'arrêter est la première source d'erreur.
    public var idleThresholdSeconds: Int = 5 * 60
    public var idleDetectionInTracker = true
    public var idleDetectionInPomodoro = false

    public init() {}

    public func idleDetectionEnabled(in mode: SessionMode) -> Bool {
        mode == .tracker ? idleDetectionInTracker : idleDetectionInPomodoro
    }
}

/// Pause proposée après un pomodoro allé à son terme (FR-020).
public enum BreakKind: Sendable, Equatable {
    case short(Duration)
    case long(Duration)

    public var duration: Duration {
        switch self { case .short(let value), .long(let value): return value }
    }
}

/// Événements de la machine. Nommés et injectables : c'est ce qui la rend
/// testable sans machine réelle ni attente (principe VII, data-model §4).
public enum SessionEvent: Sendable, Equatable {
    case start(taskPageID: String, mode: SessionMode, target: Duration?)
    case startBreak(BreakKind)
    /// Battement régulier. Seul événement qui fait arriver un pomodoro à terme.
    case tick
    case pause
    case resume
    case stopByUser
    case systemWillSleep
    case systemDidWake
    /// Inactivité constatée par le système, en secondes cumulées (FR-024).
    case idleDetected(seconds: Int)
}

public enum RefusalReason: Sendable, Equatable {
    case noTaskSelected
    case alreadyRunning
    /// FR-018 : le mode Pomodoro n'offre pas de pause manuelle.
    case pauseUnavailableInPomodoro
    case nothingRunning
}

public enum SessionResult: Sendable, Equatable {
    case none
    case refused(RefusalReason)
    /// FR-023 : sous 60 s, rien n'est envoyé — mais l'utilisateur est informé.
    case ignored(effectiveSeconds: Int)
    /// Session éligible. `nextBreak` n'est renseigné qu'après un pomodoro allé
    /// à son terme.
    case finished(CompletedSession, nextBreak: BreakKind?)
    case breakEnded
}

/// Session close et éligible à l'envoi.
public struct CompletedSession: Sendable, Equatable {
    public let localID: UUID
    public let taskPageID: String
    public let mode: SessionMode
    public let startedAt: Date
    public let endedAt: Date
    public let effectiveSeconds: Int
    public let outcome: SessionOutcome
    /// Reste local : publié dans le commentaire, jamais dans une propriété.
    public let shortenReason: ShortenReason?
    public let subtractedIdleSeconds: Int
    /// Inactivité détectée mais **pas encore arbitrée** (FR-024).
    ///
    /// Non nulle, elle signale à l'interface qu'il faut demander à l'utilisateur
    /// s'il conserve ou retranche, avant toute mise en file.
    public let pendingIdleSeconds: Int

    public init(localID: UUID, taskPageID: String, mode: SessionMode,
                startedAt: Date, endedAt: Date, effectiveSeconds: Int,
                outcome: SessionOutcome, shortenReason: ShortenReason?,
                subtractedIdleSeconds: Int, pendingIdleSeconds: Int = 0) {
        self.localID = localID
        self.taskPageID = taskPageID
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.effectiveSeconds = effectiveSeconds
        self.outcome = outcome
        self.shortenReason = shortenReason
        self.subtractedIdleSeconds = subtractedIdleSeconds
        self.pendingIdleSeconds = pendingIdleSeconds
    }

    /// FR-024 — retranche l'inactivité. Le **résultat** ne change pas : un
    /// pomodoro allé à son terme dont on retranche de l'inactivité reste
    /// « Complété », et la série n'en souffre pas.
    public func subtractingIdle() -> CompletedSession {
        CompletedSession(localID: localID, taskPageID: taskPageID, mode: mode,
                         startedAt: startedAt, endedAt: endedAt,
                         effectiveSeconds: max(0, effectiveSeconds - pendingIdleSeconds),
                         outcome: outcome, shortenReason: shortenReason,
                         subtractedIdleSeconds: subtractedIdleSeconds + pendingIdleSeconds,
                         pendingIdleSeconds: 0)
    }

    /// L'utilisateur estime avoir travaillé : la durée reste entière.
    public func keepingIdle() -> CompletedSession {
        CompletedSession(localID: localID, taskPageID: taskPageID, mode: mode,
                         startedAt: startedAt, endedAt: endedAt,
                         effectiveSeconds: effectiveSeconds, outcome: outcome,
                         shortenReason: shortenReason,
                         subtractedIdleSeconds: subtractedIdleSeconds, pendingIdleSeconds: 0)
    }
}

/// Ce qu'une session retrouvée au démarrage devient (US5.6).
public enum RestoredSession: Sendable, Equatable {
    case nothing
    /// Pomodoro clôturé d'office, daté du dernier battement connu.
    case closed(CompletedSession)
    /// Tracker présenté en pause : l'utilisateur décide.
    case paused(SessionSnapshot)
}

/// État persistable de la session en cours (FR-022).
public struct SessionSnapshot: Sendable, Equatable {
    public var localID: UUID
    public var taskPageID: String
    public var mode: SessionMode
    public var targetSeconds: Int?
    public var startedAt: Date
    public var state: SessionRunState
    public var pauseIntervals: [DateInterval]
    public var idleIntervals: [DateInterval]
    public var completedPomodoroStreak: Int
    public var lastHeartbeatAt: Date
    /// Une pause de repos n'est pas une session de travail : elle ne produit
    /// jamais d'entrée, mais doit survivre à un redémarrage.
    public var isBreak: Bool

    public init(localID: UUID, taskPageID: String, mode: SessionMode,
                targetSeconds: Int?, startedAt: Date, state: SessionRunState,
                pauseIntervals: [DateInterval] = [], idleIntervals: [DateInterval] = [],
                completedPomodoroStreak: Int, lastHeartbeatAt: Date, isBreak: Bool = false) {
        self.localID = localID
        self.taskPageID = taskPageID
        self.mode = mode
        self.targetSeconds = targetSeconds
        self.startedAt = startedAt
        self.state = state
        self.pauseIntervals = pauseIntervals
        self.idleIntervals = idleIntervals
        self.completedPomodoroStreak = completedPomodoroStreak
        self.lastHeartbeatAt = lastHeartbeatAt
        self.isBreak = isBreak
    }
}

/// Persistance de l'état de session, injectée pour rester testable sans SwiftData.
public protocol SessionPersistence: Sendable {
    /// `nil` efface la session courante.
    func save(_ snapshot: SessionSnapshot?) async
    func load() async -> SessionSnapshot?
}

/// Machine à états des sessions (data-model §4).
///
/// **Invariant central** : aucune transition ne rend la main sans avoir réécrit
/// l'état. Un arrêt inopiné entre deux instructions doit retrouver une session
/// cohérente, jamais un magasin en retard d'un événement (FR-022).
public actor SessionMachine {

    /// FR-023 — plancher d'éligibilité.
    /// Écart entre deux ticks au-delà duquel le processus a manifestement été
    /// suspendu. Trente secondes : le journal réel montre des ticks à une ou deux
    /// secondes d'intervalle, jamais plus.
    public static let suspensionThreshold = Duration.seconds(30)

    public static let minimumEffectiveSeconds = 60

    private let time: TimeSource
    private let persistence: SessionPersistence
    private let log: SessionLog?
    private var settings: SessionSettings

    public private(set) var snapshot: SessionSnapshot?
    /// Pomodoros consécutifs allés à leur terme (FR-020).
    public private(set) var streak = 0

    public init(time: TimeSource, persistence: SessionPersistence,
                settings: SessionSettings = SessionSettings(), log: SessionLog? = nil) {
        self.time = time
        self.persistence = persistence
        self.settings = settings
        self.log = log
    }

    public func update(settings: SessionSettings) { self.settings = settings }

    /// Reprend la main sur l'état persisté, sans rien décider.
    public func restore() async {
        snapshot = await persistence.load()
        streak = snapshot?.completedPomodoroStreak ?? streak
    }

    /// US5.6 — traite une session retrouvée après un arrêt inopiné.
    ///
    /// Un pomodoro est clôturé d'office : sa cible est dépassée ou son décompte
    /// perdu, et le laisser courir fausserait la durée. Un Tracker, lui, est
    /// présenté **en pause** : sa durée est libre, l'utilisateur peut vouloir
    /// reprendre. On ne tranche pas à sa place.
    ///
    /// La fin est datée du dernier battement connu — le dernier instant où l'on
    /// sait que l'application vivait.
    public func restoreSession() async -> RestoredSession {
        await restore()
        guard let current = snapshot else { return .nothing }

        // Une pause de repos n'a jamais produit d'entrée : rien à restaurer.
        guard !current.isBreak else {
            await persist(nil)
            return .nothing
        }

        if current.mode == .pomodoro {
            let result = await close(current, at: current.lastHeartbeatAt,
                                     outcome: .shortened, reason: .unexpectedQuit)
            if case .finished(let session, _) = result {
                await log?.log(.session, "session retrouvée close au dernier battement")
                return .closed(session)
            }
            return .nothing
        }

        var paused = current
        if paused.state == .running {
            paused.state = .paused
            paused.pauseIntervals.append(DateInterval(start: current.lastHeartbeatAt, duration: 0))
        }
        await persist(paused)
        await log?.log(.session, "suivi libre retrouvé, présenté en pause")
        return .paused(paused)
    }

    @discardableResult
    public func handle(_ event: SessionEvent) async -> SessionResult {
        let result = await apply(event)
        await log?.log(.session, "événement=\(event.name) → \(result.name)")
        return result
    }

    // MARK: - Transitions

    private func apply(_ event: SessionEvent) async -> SessionResult {
        switch event {
        case .start(let taskPageID, let mode, let target):
            return await start(taskPageID: taskPageID, mode: mode, target: target)
        case .startBreak(let kind):
            return await startBreak(kind)
        case .tick:
            return await tick()
        case .pause:
            return await pause(cause: .user)
        case .resume:
            return await resume()
        case .stopByUser:
            return await stop(reason: .user, at: time.wallClock)
        case .systemWillSleep:
            return await sleep()
        case .systemDidWake:
            return await resume()
        case .idleDetected(let seconds):
            return await noteIdle(seconds: seconds)
        }
    }

    /// FR-024 — accumule l'inactivité constatée, si le mode l'active.
    ///
    /// On mémorise seulement la durée : l'arbitrage — conserver ou retrancher —
    /// n'a lieu qu'à la clôture, quand l'utilisateur peut décider en connaissance
    /// de cause.
    private func noteIdle(seconds: Int) async -> SessionResult {
        guard var current = snapshot, !current.isBreak, seconds > 0 else { return .none }
        guard settings.idleDetectionEnabled(in: current.mode) else { return .none }

        let end = time.wallClock
        current.idleIntervals.append(
            DateInterval(start: end.addingTimeInterval(TimeInterval(-seconds)), end: end))
        current.lastHeartbeatAt = end
        await persist(current)
        await log?.log(.session, "inactivité constatée=\(seconds)s mode=\(current.mode.rawValue)")
        return .none
    }

    private func start(taskPageID: String, mode: SessionMode,
                       target: Duration?) async -> SessionResult {
        guard !taskPageID.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .refused(.noTaskSelected)
        }
        // FR-017 : une seule session à la fois. Une pause de repos, elle, cède
        // la place — repartir immédiatement est explicitement prévu (US2.2).
        if let current = snapshot {
            guard current.isBreak else { return .refused(.alreadyRunning) }
            await persist(nil)
        }

        let now = time.wallClock
        let seconds = target.map { Int($0.seconds.rounded()) }
            ?? (mode == .pomodoro ? settings.pomodoroSeconds : nil)
        await persist(SessionSnapshot(localID: UUID(), taskPageID: taskPageID, mode: mode,
                                      targetSeconds: mode == .pomodoro ? seconds : nil,
                                      startedAt: now, state: .running,
                                      completedPomodoroStreak: streak, lastHeartbeatAt: now))
        return .none
    }

    private func startBreak(_ kind: BreakKind) async -> SessionResult {
        let now = time.wallClock
        await persist(SessionSnapshot(localID: UUID(), taskPageID: "", mode: .pomodoro,
                                      targetSeconds: Int(kind.duration.seconds.rounded()),
                                      startedAt: now, state: .running,
                                      completedPomodoroStreak: streak,
                                      lastHeartbeatAt: now, isBreak: true))
        return .none
    }

    private func tick() async -> SessionResult {
        guard var current = snapshot else { return .refused(.nothingRunning) }
        let now = time.wallClock

        // Filet de sécurité, indépendant des notifications système : le minuteur
        // bat à la seconde, et la gigue ordinaire se compte en secondes. Un
        // écart de cet ordre prouve que le processus n'a pas tourné — veille non
        // annoncée, clapet fermé sur écran externe, application suspendue par le
        // système. On ne devine pas la cause, on constate l'absence.
        let sinceLastTick = now.timeIntervalSince(current.lastHeartbeatAt)
        if sinceLastTick >= SessionMachine.suspensionThreshold.seconds {
            return await handleSuspension(current, from: current.lastHeartbeatAt, to: now)
        }

        current.lastHeartbeatAt = now

        // Un pomodoro n'arrive à son terme que par le compte à rebours ; le
        // Tracker, jamais — il court jusqu'à l'arrêt explicite.
        if let target = current.targetSeconds,
           now.timeIntervalSince(current.startedAt) >= TimeInterval(target),
           current.state == .running {
            if current.isBreak {
                await persist(nil)
                return .breakEnded
            }
            return await complete(current, at: current.startedAt.addingTimeInterval(TimeInterval(target)))
        }

        await persist(current)
        return .none
    }

    /// Traite une suspension constatée après coup.
    ///
    /// Le temps suspendu n'a pas été travaillé : la seule date sûre est celle du
    /// dernier tick. Les règles sont celles de la veille annoncée (FR-021,
    /// US5.3) — un pomodoro est clos et écourté, un suivi libre se poursuit sans
    /// compter le trou, une pause est terminée.
    private func handleSuspension(_ current: SessionSnapshot,
                                  from lastKnown: Date, to now: Date) async -> SessionResult {
        let gap = Int(now.timeIntervalSince(lastKnown).rounded())
        await log?.log(.session, "saut d'horloge \(gap)s — processus suspendu sans veille annoncée")

        if current.isBreak {
            await persist(nil)
            return .breakEnded
        }
        if current.mode == .pomodoro {
            return await close(current, at: lastKnown, outcome: .shortened, reason: .sleep)
        }

        var updated = current
        // Déjà en pause — la veille avait bien été annoncée, le saut n'en est que
        // la conséquence : la pause court toujours, en ajouter une seconde
        // retrancherait le même temps deux fois.
        if updated.state == .running {
            updated.pauseIntervals.append(DateInterval(start: lastKnown, end: now))
        }
        updated.lastHeartbeatAt = now
        await persist(updated)
        return .none
    }

    private func pause(cause: ShortenReason) async -> SessionResult {
        guard var current = snapshot else { return .refused(.nothingRunning) }
        // FR-018 : refus explicite plutôt que silencieux, pour que l'interface
        // n'ait pas à connaître la règle.
        guard current.mode == .tracker || current.isBreak else {
            return .refused(.pauseUnavailableInPomodoro)
        }
        guard current.state == .running else { return .none }

        current.state = .paused
        current.pauseIntervals.append(DateInterval(start: time.wallClock, duration: 0))
        current.lastHeartbeatAt = time.wallClock
        await persist(current)
        return .none
    }

    private func resume() async -> SessionResult {
        guard var current = snapshot else { return .none }
        guard current.state == .paused, var last = current.pauseIntervals.last else { return .none }

        last.end = max(time.wallClock, last.start)
        current.pauseIntervals[current.pauseIntervals.count - 1] = last
        current.state = .running
        current.lastHeartbeatAt = time.wallClock
        await persist(current)
        return .none
    }

    /// Mise en veille. Le traitement complet — pomodoro clôturé, tracker mis en
    /// pause — relève de l'US5 ; la clôture datée est déjà en place ici parce
    /// que la persistance doit être juste dès maintenant.
    private func sleep() async -> SessionResult {
        guard let current = snapshot else { return .none }
        if current.isBreak {
            await persist(nil)
            return .breakEnded
        }
        if current.mode == .pomodoro {
            return await stop(reason: .sleep, at: time.wallClock)
        }
        return await pause(cause: .sleep)
    }

    private func stop(reason: ShortenReason, at end: Date) async -> SessionResult {
        guard let current = snapshot else { return .refused(.nothingRunning) }
        if current.isBreak {
            // Une pause interrompue n'est rien d'autre qu'une pause terminée :
            // elle ne produit aucune entrée (FR-020).
            await persist(nil)
            return .breakEnded
        }
        // Arrêter un suivi libre est son déroulement normal : l'utilisateur en
        // fixe lui-même la durée, il n'y a aucune cible à manquer. Le classer
        // « Écourté » ferait passer chaque session Tracker pour un incident
        // (data-model §4, US4.3).
        if current.mode == .tracker && reason == .user {
            return await close(current, at: end, outcome: .ranToTerm, reason: nil)
        }
        return await close(current, at: end, outcome: .shortened, reason: reason)
    }

    private func complete(_ current: SessionSnapshot, at end: Date) async -> SessionResult {
        await close(current, at: end, outcome: .ranToTerm, reason: nil)
    }

    /// Clôture commune : durée effective, éligibilité, série, pause proposée.
    private func close(_ current: SessionSnapshot, at end: Date,
                       outcome: SessionOutcome, reason: ShortenReason?) async -> SessionResult {
        let effective = effectiveSeconds(of: current, until: end)

        guard effective >= SessionMachine.minimumEffectiveSeconds else {
            // FR-023 : la session n'a pas eu lieu. La série n'en souffre pas —
            // ce n'est pas un écourtement, c'est un non-événement.
            await persist(nil)
            await log?.log(.session, "session ignorée durée=\(effective)s < 60s")
            return .ignored(effectiveSeconds: effective)
        }

        var suggestion: BreakKind?
        if outcome == .ranToTerm && current.mode == .pomodoro {
            streak += 1
            if streak >= settings.pomodorosBeforeLongBreak {
                suggestion = .long(.seconds(settings.longBreakSeconds))
                streak = 0
            } else {
                suggestion = .short(.seconds(settings.shortBreakSeconds))
            }
        } else if outcome == .shortened && current.mode == .pomodoro {
            streak = 0
        }

        let session = CompletedSession(localID: current.localID,
                                       taskPageID: current.taskPageID,
                                       mode: current.mode,
                                       startedAt: current.startedAt,
                                       endedAt: end,
                                       effectiveSeconds: effective,
                                       outcome: outcome,
                                       shortenReason: reason,
                                       subtractedIdleSeconds: 0,
                                       pendingIdleSeconds: pendingIdle(of: current, until: end))
        await persist(nil)
        await log?.log(.session, "session close mode=\(current.mode.rawValue) "
                       + "durée=\(effective)s issue=\(outcome.rawValue) série=\(streak)")
        return .finished(session, nextBreak: suggestion)
    }

    /// Durée réellement travaillée : temps écoulé moins les pauses.
    ///
    /// Un pomodoro allé à son terme vaut sa durée cible et non le temps écoulé :
    /// un tick retardé — l'app était occupée — ne doit pas gonfler l'entrée.
    private func effectiveSeconds(of current: SessionSnapshot, until end: Date) -> Int {
        let elapsed = end.timeIntervalSince(current.startedAt)
        let paused = current.pauseIntervals.reduce(0.0) { total, interval in
            total + max(0, min(interval.end, end).timeIntervalSince(interval.start))
        }
        // L'inactivité n'est **pas** retranchée ici : elle est soumise à
        // l'utilisateur, qui peut l'avoir passée à lire ou à réfléchir (FR-024).
        return max(0, Int((elapsed - paused).rounded()))
    }

    /// Inactivité détectée pendant la session, en attente d'arbitrage.
    private func pendingIdle(of current: SessionSnapshot, until end: Date) -> Int {
        guard settings.idleDetectionEnabled(in: current.mode) else { return 0 }
        let total = current.idleIntervals
            .filter { $0.start < end }
            .reduce(0.0) { $0 + min($1.end, end).timeIntervalSince($1.start) }
        return max(0, Int(total.rounded()))
    }

    /// Écrit **avant** de rendre la main. Tout le reste de la machine en dépend.
    private func persist(_ next: SessionSnapshot?) async {
        var next = next
        next?.completedPomodoroStreak = streak
        snapshot = next
        await persistence.save(next)
    }
}

private extension SessionEvent {
    var name: String {
        switch self {
        case .start: return "démarrer"
        case .startBreak: return "pause-repos"
        case .tick: return "tick"
        case .pause: return "mettre-en-pause"
        case .resume: return "reprendre"
        case .stopByUser: return "arrêter"
        case .systemWillSleep: return "veille"
        case .systemDidWake: return "réveil"
        case .idleDetected(let seconds): return "inactivité(\(seconds)s)"
        }
    }
}

private extension SessionResult {
    var name: String {
        switch self {
        case .none: return "poursuite"
        case .refused(let reason): return "refusé(\(reason))"
        case .ignored(let seconds): return "ignorée(\(seconds)s)"
        case .finished(let session, let next):
            return "close(\(session.outcome.rawValue), pause=\(next == nil ? "non" : "oui"))"
        case .breakEnded: return "pause-terminée"
        }
    }
}
