import Foundation
import SwiftData

// Modèle local, conforme à `data-model.md` §1.
//
// Ce magasin n'est **que** du cache de lecture, de l'état de session en cours et
// de la file d'envoi : Notion reste la source de vérité (principe II). Aucun token
// n'y figure — ils vivent au Keychain (principe III).

// MARK: - Énumérations persistées

// Stockées en `String` brute avec un accesseur typé : c'est plus verbeux qu'un enum
// natif, mais ça survit à un renommage de cas sans migration de magasin.

public enum DatabaseRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case tasks, timeEntries, projects

    public var id: String { rawValue }
}

public enum SessionMode: String, Codable, Sendable {
    case pomodoro, tracker
}

public enum SessionRunState: String, Codable, Sendable {
    case running, paused
}

/// Résultat local d'une session. Détermine la valeur écrite dans la propriété
/// Statut de Notion et la remise à zéro de la série de pomodoros (FR-019, FR-020).
public enum SessionOutcome: String, Codable, Sendable {
    case ranToTerm
    case shortened
    case ignored

    /// Valeur écrite dans Notion. `ignored` ne produit aucune entrée (FR-023).
    public var notionStatus: String? {
        switch self {
        case .ranToTerm: return "Complété"
        case .shortened: return "Écourté"
        case .ignored: return nil
        }
    }
}

/// Cause d'un écourtement. Reste locale : elle n'est publiée que dans le
/// commentaire de la page, jamais dans une propriété (FR-026a).
public enum ShortenReason: String, Codable, Sendable {
    case user, sleep, unexpectedQuit
}

/// Issue de la dernière tentative d'envoi. Pilote, et elle seule, le déclenchement
/// de la vérification d'idempotence au réessai (FR-028, R-06).
public enum AttemptOutcome: String, Codable, Sendable {
    case neverAttempted
    /// Notion a répondu une erreur explicite : aucune page n'a été créée.
    case explicitError
    /// Aucune réponse reçue. On ne sait pas si la page existe.
    case indeterminate

    /// Seul ce cas impose la vérification préalable par identifiant local.
    public var requiresIdempotencyCheck: Bool { self == .indeterminate }
}

public enum SendState: String, Codable, Sendable {
    case pending
    case failedPermanently
}

// MARK: - Connexion

@Model
public final class NotionConnection {
    @Attribute(.unique) public var workspaceID: String
    public var workspaceName: String
    public var workspaceIconURL: URL?
    /// Valeur brute de `workspace_icon` : emoji ou adresse, indifféremment.
    public var workspaceIconRaw: String?
    public var botID: String
    /// Identifie l'utilisateur courant : filtre Personne et remplissage de la
    /// propriété Personne des entrées (FR-011, FR-026).
    public var ownerUserID: String
    public var ownerName: String
    /// Vide si l'utilisateur a désigné des pages existantes (FR-004 / FR-005).
    public var duplicatedTemplateID: String?
    public var connectedAt: Date

    /// Icône telle qu'elle doit être affichée, quelle que soit sa forme.
    public var icon: WorkspaceIcon {
        WorkspaceIcon.parse(workspaceIconRaw ?? workspaceIconURL?.absoluteString)
    }

    public init(workspaceID: String, workspaceName: String, workspaceIconURL: URL? = nil,
                workspaceIconRaw: String? = nil,
                botID: String, ownerUserID: String, ownerName: String,
                duplicatedTemplateID: String? = nil, connectedAt: Date) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspaceIconURL = workspaceIconURL
        self.workspaceIconRaw = workspaceIconRaw
        self.botID = botID
        self.ownerUserID = ownerUserID
        self.ownerName = ownerName
        self.duplicatedTemplateID = duplicatedTemplateID
        self.connectedAt = connectedAt
    }
}

// MARK: - Liaison d'un rôle à une source de données

/// Un rôle est lié à une **source de données**, jamais à une base (R-01).
/// `databaseID` n'est retenu que pour l'affichage, l'ouverture dans Notion et la
/// re-résolution des sources lors d'une revalidation.
@Model
public final class DatabaseBinding {
    @Attribute(.unique) public var roleRaw: String
    public var databaseID: String
    public var dataSourceID: String
    public var dataSourceName: String
    public var title: String
    /// Mapping clé logique → propriété réelle, sérialisé (voir `PropertyRef`).
    public var propertyMapData: Data
    /// La source déclare un modèle de page par défaut.
    ///
    /// Constaté à la liaison plutôt qu'à chaque envoi : c'est une propriété de la
    /// base, qui ne change pas d'une session à l'autre, et une requête de plus
    /// par entrée coûterait le quota pour rien.
    public var usesDefaultTemplate: Bool = false
    public var lastValidatedAt: Date?
    public var validationStateRaw: String

    public var role: DatabaseRole? {
        get { DatabaseRole(rawValue: roleRaw) }
        set { if let newValue { roleRaw = newValue.rawValue } }
    }

    public init(role: DatabaseRole, databaseID: String, dataSourceID: String,
                dataSourceName: String, title: String,
                propertyMap: [String: PropertyRef] = [:],
                lastValidatedAt: Date? = nil, validationState: String = "unvalidated",
                usesDefaultTemplate: Bool = false) {
        self.roleRaw = role.rawValue
        self.databaseID = databaseID
        self.dataSourceID = dataSourceID
        self.dataSourceName = dataSourceName
        self.title = title
        self.propertyMapData = (try? JSONEncoder().encode(propertyMap)) ?? Data()
        self.lastValidatedAt = lastValidatedAt
        self.validationStateRaw = validationState
        self.usesDefaultTemplate = usesDefaultTemplate
    }

    public var propertyMap: [String: PropertyRef] {
        get { (try? JSONDecoder().decode([String: PropertyRef].self, from: propertyMapData)) ?? [:] }
        set { propertyMapData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

/// Référence à une propriété Notion. L'`id` est stable au renommage : c'est lui
/// qui sert aux requêtes, le `name` ne servant qu'à l'affichage et au re-mapping.
public struct PropertyRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    /// Options d'un `select` ou d'un `status`, dans l'ordre du schéma.
    ///
    /// Indispensables pour un `status` : l'API n'en crée aucune à la volée, et
    /// n'accepte que les valeurs déjà déclarées. Les conserver ici évite de
    /// relire la source à chaque envoi.
    public var options: [String]
    /// Options du groupe « terminé », pour un `status`. Vide pour un `select`.
    ///
    /// Persistées avec la liaison : c'est ce qui permet de filtrer les tâches
    /// terminées sans relire le schéma, et sans qu'aucun libellé ne soit écrit
    /// dans le code.
    public var completeOptions: [String]

    public init(id: String, name: String, type: String,
                options: [String] = [], completeOptions: [String] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.options = options
        self.completeOptions = completeOptions
    }

    /// Décodage tolérant : les liaisons enregistrées avant l'ajout du champ
    /// n'en portent pas, et doivent rester lisibles.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(String.self, forKey: .type)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        completeOptions = try container.decodeIfPresent([String].self, forKey: .completeOptions) ?? []
    }
}

// MARK: - Cache de lecture

@Model
public final class CachedTask {
    @Attribute(.unique) public var pageID: String
    public var title: String
    public var statusValue: String?
    public var assigneeIDs: [String]
    public var projectPageID: String?
    /// Titre + projet, minuscules et sans diacritiques, pré-calculé pour FR-013.
    public var searchKey: String
    public var lastSyncedAt: Date

    public init(pageID: String, title: String, statusValue: String? = nil,
                assigneeIDs: [String] = [], projectPageID: String? = nil,
                searchKey: String, lastSyncedAt: Date) {
        self.pageID = pageID
        self.title = title
        self.statusValue = statusValue
        self.assigneeIDs = assigneeIDs
        self.projectPageID = projectPageID
        self.searchKey = searchKey
        self.lastSyncedAt = lastSyncedAt
    }
}

@Model
public final class CachedProject {
    @Attribute(.unique) public var pageID: String
    public var title: String

    public init(pageID: String, title: String) {
        self.pageID = pageID
        self.title = title
    }
}

@Model
public final class RecentTaskUse {
    @Attribute(.unique) public var taskPageID: String
    public var lastUsedAt: Date

    public init(taskPageID: String, lastUsedAt: Date) {
        self.taskPageID = taskPageID
        self.lastUsedAt = lastUsedAt
    }
}

// MARK: - Session en cours

/// Zéro ou une instance. **Réécrite à chaque transition** : c'est ce qui rend la
/// reprise après arrêt inopiné possible (FR-022, US5.6).
@Model
public final class ActiveSession {
    @Attribute(.unique) public var localID: UUID
    public var taskPageID: String
    public var modeRaw: String
    /// Durée cible en secondes, mode Pomodoro seulement.
    public var targetSeconds: Int?
    public var startedAt: Date
    public var stateRaw: String
    public var pauseIntervalsData: Data
    public var idleIntervalsData: Data
    public var completedPomodoroStreak: Int
    /// Écrit à chaque transition et à chaque tick : sert à dater la fin d'une
    /// session retrouvée après un arrêt inopiné.
    public var lastHeartbeatAt: Date

    public init(localID: UUID, taskPageID: String, mode: SessionMode,
                targetSeconds: Int? = nil, startedAt: Date,
                state: SessionRunState = .running,
                pauseIntervals: [DateInterval] = [], idleIntervals: [DateInterval] = [],
                completedPomodoroStreak: Int = 0, lastHeartbeatAt: Date) {
        self.localID = localID
        self.taskPageID = taskPageID
        self.modeRaw = mode.rawValue
        self.targetSeconds = targetSeconds
        self.startedAt = startedAt
        self.stateRaw = state.rawValue
        self.pauseIntervalsData = ActiveSession.encode(pauseIntervals)
        self.idleIntervalsData = ActiveSession.encode(idleIntervals)
        self.completedPomodoroStreak = completedPomodoroStreak
        self.lastHeartbeatAt = lastHeartbeatAt
    }

    public var mode: SessionMode { SessionMode(rawValue: modeRaw) ?? .tracker }

    public var state: SessionRunState {
        get { SessionRunState(rawValue: stateRaw) ?? .running }
        set { stateRaw = newValue.rawValue }
    }

    public var pauseIntervals: [DateInterval] {
        get { ActiveSession.decode(pauseIntervalsData) }
        set { pauseIntervalsData = ActiveSession.encode(newValue) }
    }

    public var idleIntervals: [DateInterval] {
        get { ActiveSession.decode(idleIntervalsData) }
        set { idleIntervalsData = ActiveSession.encode(newValue) }
    }

    static func encode(_ intervals: [DateInterval]) -> Data {
        (try? JSONEncoder().encode(intervals)) ?? Data()
    }

    static func decode(_ data: Data) -> [DateInterval] {
        (try? JSONDecoder().decode([DateInterval].self, from: data)) ?? []
    }
}

// MARK: - File d'envoi

/// Une entrée est créée **avant** toute tentative réseau et n'en sort que sur
/// confirmation que la page existe (FR-027).
@Model
public final class OutboxEntry {
    @Attribute(.unique) public var localID: UUID
    public var taskPageID: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationMinutes: Int
    public var modeRaw: String
    public var outcomeRaw: String
    public var shortenReasonRaw: String?
    public var subtractedIdleMinutes: Int
    public var sendStateRaw: String
    public var failureCause: String?
    public var attemptOutcomeRaw: String
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    /// Connu seulement après une création confirmée. Indisponible dans le cas
    /// d'issue indéterminée, ce qui borne la détection d'une page en corbeille (R-06).
    public var createdPageID: String?
    /// Best-effort : son échec ne remet jamais l'entrée en file (FR-026a).
    public var commentPosted: Bool

    public init(localID: UUID, taskPageID: String, title: String,
                startedAt: Date, endedAt: Date, durationMinutes: Int,
                mode: SessionMode, outcome: SessionOutcome,
                shortenReason: ShortenReason? = nil, subtractedIdleMinutes: Int = 0,
                sendState: SendState = .pending, failureCause: String? = nil,
                attemptOutcome: AttemptOutcome = .neverAttempted, attemptCount: Int = 0,
                nextAttemptAt: Date? = nil, createdPageID: String? = nil,
                commentPosted: Bool = false) {
        self.localID = localID
        self.taskPageID = taskPageID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMinutes = durationMinutes
        self.modeRaw = mode.rawValue
        self.outcomeRaw = outcome.rawValue
        self.shortenReasonRaw = shortenReason?.rawValue
        self.subtractedIdleMinutes = subtractedIdleMinutes
        self.sendStateRaw = sendState.rawValue
        self.failureCause = failureCause
        self.attemptOutcomeRaw = attemptOutcome.rawValue
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.createdPageID = createdPageID
        self.commentPosted = commentPosted
    }

    public var mode: SessionMode { SessionMode(rawValue: modeRaw) ?? .tracker }
    public var outcome: SessionOutcome { SessionOutcome(rawValue: outcomeRaw) ?? .ranToTerm }
    public var shortenReason: ShortenReason? { shortenReasonRaw.flatMap(ShortenReason.init(rawValue:)) }

    public var sendState: SendState {
        get { SendState(rawValue: sendStateRaw) ?? .pending }
        set { sendStateRaw = newValue.rawValue }
    }

    public var attemptOutcome: AttemptOutcome {
        get { AttemptOutcome(rawValue: attemptOutcomeRaw) ?? .neverAttempted }
        set { attemptOutcomeRaw = newValue.rawValue }
    }

    /// Un commentaire n'est publié que pour un écourtement ou un retranchement
    /// d'inactivité — jamais pour une session allée à son terme sans retrait (FR-026a).
    public var needsComment: Bool {
        outcome == .shortened || subtractedIdleMinutes > 0
    }
}

// MARK: - Réglages

@Model
public final class AppSettings {
    @Attribute(.unique) public var singletonKey: String
    public var pomodoroMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    public var pomodorosBeforeLongBreak: Int
    public var idleDetectionEnabledTracker: Bool
    public var idleDetectionEnabledPomodoro: Bool
    public var idleThresholdMinutes: Int
    public var notificationsEnabled: Bool
    public var soundEnabled: Bool
    public var launchAtLogin: Bool
    public var focusShortcutName: String?
    public var taskRefreshIntervalMinutes: Int
    public var showUnassignedTasks: Bool
    public var doneStatusValues: [String]

    /// Les valeurs par défaut doivent permettre d'utiliser l'app sans jamais
    /// ouvrir les réglages (US7). Elles reprennent FR-018 et FR-024.
    public init(pomodoroMinutes: Int = 25, shortBreakMinutes: Int = 5, longBreakMinutes: Int = 15,
                pomodorosBeforeLongBreak: Int = 4,
                idleDetectionEnabledTracker: Bool = true,
                idleDetectionEnabledPomodoro: Bool = false,
                idleThresholdMinutes: Int = 5,
                notificationsEnabled: Bool = true, soundEnabled: Bool = true,
                launchAtLogin: Bool = false, focusShortcutName: String? = nil,
                taskRefreshIntervalMinutes: Int = 5, showUnassignedTasks: Bool = false,
                // Vide par défaut : c'est le groupe « terminé » du schéma qui
                // dit ce qu'être terminé veut dire dans la base de l'utilisateur.
                // Une liste écrite ici serait du vocabulaire supposé — et « Done »
                // faisait rejeter la requête entière sur une base francophone.
                doneStatusValues: [String] = []) {
        self.singletonKey = "settings"
        self.pomodoroMinutes = pomodoroMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.pomodorosBeforeLongBreak = pomodorosBeforeLongBreak
        self.idleDetectionEnabledTracker = idleDetectionEnabledTracker
        self.idleDetectionEnabledPomodoro = idleDetectionEnabledPomodoro
        self.idleThresholdMinutes = idleThresholdMinutes
        self.notificationsEnabled = notificationsEnabled
        self.soundEnabled = soundEnabled
        self.launchAtLogin = launchAtLogin
        self.focusShortcutName = focusShortcutName
        self.taskRefreshIntervalMinutes = taskRefreshIntervalMinutes
        self.showUnassignedTasks = showUnassignedTasks
        self.doneStatusValues = doneStatusValues
    }
}

/// Préréglages Pomodoro de FR-018.
public enum PomodoroPreset: String, CaseIterable, Sendable {
    case classic, extended

    public var label: String {
        switch self {
        case .classic: return "25 / 5 / 15"
        case .extended: return "50 / 10 / 20"
        }
    }

    public var pomodoroMinutes: Int { self == .classic ? 25 : 50 }
    public var shortBreakMinutes: Int { self == .classic ? 5 : 10 }
    public var longBreakMinutes: Int { self == .classic ? 15 : 20 }
}

public extension AppSettings {
    /// Traduction vers les réglages de la machine à états.
    ///
    /// Les valeurs sont bornées ici plutôt qu'à la saisie : le magasin peut
    /// contenir n'importe quoi après une migration ou une édition manuelle, et
    /// un pomodoro de zéro minute se terminerait avant d'avoir commencé.
    var sessionSettings: SessionSettings {
        var settings = SessionSettings()
        settings.pomodoroSeconds = max(1, pomodoroMinutes) * 60
        settings.shortBreakSeconds = max(1, shortBreakMinutes) * 60
        settings.longBreakSeconds = max(1, longBreakMinutes) * 60
        settings.pomodorosBeforeLongBreak = max(1, pomodorosBeforeLongBreak)
        settings.idleThresholdSeconds = max(1, idleThresholdMinutes) * 60
        settings.idleDetectionInTracker = idleDetectionEnabledTracker
        settings.idleDetectionInPomodoro = idleDetectionEnabledPomodoro
        return settings
    }

    /// Traduction vers les filtres du cache de tâches.
    func taskFilterSettings(currentUserID: String?) -> TaskFilterSettings {
        var settings = TaskFilterSettings()
        settings.doneStatusValues = doneStatusValues
        settings.currentUserID = currentUserID
        settings.includeUnassigned = showUnassignedTasks
        return settings
    }

    func apply(_ preset: PomodoroPreset) {
        pomodoroMinutes = preset.pomodoroMinutes
        shortBreakMinutes = preset.shortBreakMinutes
        longBreakMinutes = preset.longBreakMinutes
    }
}
