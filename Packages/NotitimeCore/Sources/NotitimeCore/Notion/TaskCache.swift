import Foundation

/// Réglages du filtrage des tâches (FR-010, FR-011, FR-014).
public struct TaskFilterSettings: Sendable, Equatable {
    /// Valeurs de statut considérées comme terminées. Configurables : chaque
    /// équipe nomme ses états autrement.
    public var doneStatusValues: [String] = []
    /// Utilisateur courant, pour le filtre Personne. `nil` désactive le filtre.
    public var currentUserID: String?
    /// US3.2 — proposer aussi les tâches sans responsable.
    public var includeUnassigned = true
    public var recentTaskCount = 5

    public init() {}
}

/// Tâche du cache, prête pour le menu.
public struct CachedTaskItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let statusValue: String?
    public let assigneeIDs: [String]
    public let projectPageID: String?
    /// Titre replié — minuscules, sans diacritiques — calculé une fois au
    /// chargement pour que la recherche reste instantanée à chaque frappe.
    public let searchKey: String
}

/// Cache des tâches ouvertes de l'utilisateur (FR-009 à FR-014).
///
/// Les filtres partent **côté API** : rapatrier une base entière pour la
/// filtrer en local coûterait le quota et le temps de démarrage. La recherche,
/// elle, est strictement locale — elle doit répondre à chaque frappe.
public actor TaskCache {

    private let client: NotionClient
    private let mapper: PropertyMapper
    private let dataSourceID: String
    private let log: SessionLog?
    private var settings: TaskFilterSettings

    public private(set) var tasks: [CachedTaskItem] = []
    /// Heure de la dernière synchronisation **réussie** (FR-015a).
    public private(set) var lastSuccessfulSync: Date?
    private var recentUses: [String: Date] = [:]
    private var useCounter = 0

    public init(client: NotionClient, mapper: PropertyMapper, dataSourceID: String,
                settings: TaskFilterSettings = TaskFilterSettings(), log: SessionLog? = nil) {
        self.client = client
        self.mapper = mapper
        self.dataSourceID = dataSourceID
        self.settings = settings
        self.log = log
    }

    public func update(settings: TaskFilterSettings) { self.settings = settings }

    // MARK: - Rafraîchissement

    /// Recharge la liste. En cas d'échec, le cache précédent reste intact et
    /// consultable : Notion injoignable n'empêche pas de démarrer une session.
    public func refresh() async throws {
        var loaded: [CachedTaskItem] = []
        var cursor: String?

        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let filter = queryFilter() { body["filter"] = filter }
            if let cursor { body["start_cursor"] = cursor }

            let page = try await client.queryDataSource(dataSourceID, body: body)
            loaded.append(contentsOf: page.results.compactMap(item(from:)))
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil

        tasks = loaded
        lastSuccessfulSync = Date()
        await log?.log(.sync, "cache de tâches rafraîchi=\(loaded.count)")
    }

    /// Filtre poussé à l'API : statut non terminé, et responsable si demandé.
    func queryFilter() -> [String: Any]? {
        var clauses: [[String: Any]] = []

        // Un `and` de `does_not_equal` plutôt qu'un `nin` : la propriété peut
        // être un `status` ou un `select`, et le conteneur diffère.
        if let reference = mapper.reference(.taskStatus), !settings.doneStatusValues.isEmpty {
            let container = reference.type == "status" ? "status" : "select"
            for value in settings.doneStatusValues {
                clauses.append(["property": reference.name,
                                container: ["does_not_equal": value]])
            }
        }

        if let reference = mapper.reference(.taskAssignee), let user = settings.currentUserID {
            let assigned: [String: Any] = ["property": reference.name,
                                           "people": ["contains": user]]
            if settings.includeUnassigned {
                clauses.append(["or": [assigned,
                                       ["property": reference.name,
                                        "people": ["is_empty": true]]]])
            } else {
                clauses.append(assigned)
            }
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : ["and": clauses]
    }

    private func item(from page: NotionPage) -> CachedTaskItem? {
        guard let title = mapper.readTitle(.taskTitle, from: page.properties), !title.isEmpty
        else { return nil }

        let project = mapper.readRelationIDs(.taskProject, from: page.properties).first
        return CachedTaskItem(id: page.id,
                              title: title,
                              statusValue: mapper.readStatusValue(.taskStatus, from: page.properties),
                              assigneeIDs: mapper.readPeopleIDs(.taskAssignee, from: page.properties),
                              projectPageID: project,
                              searchKey: TaskCache.fold(title))
    }

    /// Repli utilisé par la recherche : minuscules, sans diacritiques.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "fr_FR"))
    }

    // MARK: - Recherche (FR-013)

    /// Filtre local. Aucune requête : la liste doit répondre à chaque frappe.
    public func search(_ query: String) -> [CachedTaskItem] {
        let needle = TaskCache.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return tasks }
        return tasks.filter { $0.searchKey.contains(needle) }
    }

    // MARK: - Récentes (FR-014)

    /// Mémorise l'usage d'une tâche. Le compteur sert d'horloge logique : deux
    /// usages dans la même seconde doivent rester ordonnés.
    public func noteUse(of pageID: String) {
        useCounter += 1
        recentUses[pageID] = Date(timeIntervalSince1970: TimeInterval(useCounter))
    }

    public func restoreRecentUses(_ uses: [String: Date]) {
        recentUses = uses
        useCounter = uses.count
    }

    public func exportRecentUses() -> [String: Date] { recentUses }

    /// Récentes en tête, **hors du filtre courant** — mais seulement celles qui
    /// figurent encore dans le cache : une tâche terminée depuis n'a plus à
    /// être proposée.
    public func recentTasks() -> [CachedTaskItem] {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        return recentUses
            .sorted { $0.value > $1.value }
            .compactMap { byID[$0.key] }
            .prefix(settings.recentTaskCount)
            .map { $0 }
    }
}
