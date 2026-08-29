import Foundation

/// Réglages du filtrage des tâches (FR-010, FR-011, FR-014).
public struct TaskFilterSettings: Sendable, Equatable {
    /// Valeurs de statut à exclure **en plus** du groupe « terminé » du schéma.
    ///
    /// Vide par défaut, et c'est voulu : le schéma sait déjà ce qu'être terminé
    /// signifie dans cette base. Ce réglage sert aux cas qu'il ne couvre pas —
    /// une propriété `select`, qui n'a pas de groupes, ou une équipe qui range
    /// « À valider » parmi les tâches à ne plus proposer.
    public var doneStatusValues: [String] = []
    /// Utilisateur courant, pour le filtre Personne. `nil` désactive le filtre.
    public var currentUserID: String?
    /// FR-011 — ne proposer que les tâches qui me sont assignées.
    ///
    /// Faux par défaut, et c'est le point de ce réglage. Une base partagée porte
    /// des tâches sans responsable ; les écarter d'office donnait une liste
    /// amputée sans que rien ne le dise — deux tâches affichées sur six dans le
    /// cas qui a servi à trouver ce défaut, toutes ouvertes, toutes valides.
    /// Une liste de tâches doit d'abord contenir les tâches.
    public var onlyAssignedToMe = false
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
    /// L'échéance de la tâche, si sa base en porte une (voir `TaskDateChoice`).
    public let dueDate: Date?
    /// Titre replié — minuscules, sans diacritiques — calculé une fois au
    /// chargement pour que la recherche reste instantanée à chaque frappe.
    public let searchKey: String

    public init(id: String, title: String, statusValue: String?, assigneeIDs: [String],
                projectPageID: String?, dueDate: Date? = nil, searchKey: String) {
        self.id = id
        self.title = title
        self.statusValue = statusValue
        self.assigneeIDs = assigneeIDs
        self.projectPageID = projectPageID
        self.dueDate = dueDate
        self.searchKey = searchKey
    }
}

/// Cache des tâches ouvertes de l'utilisateur (FR-009 à FR-014).
///
/// Les filtres partent **côté API** : rapatrier une base entière pour la
/// filtrer en local coûterait le quota et le temps de démarrage. La recherche,
/// elle, est strictement locale — elle doit répondre à chaque frappe.
public actor TaskCache {

    private let client: NotionClient
    private var mapper: PropertyMapper
    private var dataSourceID: String
    private let log: SessionLog?
    private var settings: TaskFilterSettings

    public private(set) var tasks: [CachedTaskItem] = []
    /// Heure de la dernière synchronisation **réussie** (FR-015a).
    public private(set) var lastSuccessfulSync: Date?
    /// `nil` tant que le schéma n'a pas été lu ; `.some(nil)` quand il l'a été
    /// et qu'aucune propriété de date ne convient.
    private var dueProperty: String??
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

    /// Relie le cache à une autre base, ou à la même avec un schéma remis à jour.
    ///
    /// Sans cela, le cache bâti au premier chargement gardait sa source jusqu'à
    /// la fin du processus : changer la base Tâches depuis les réglages, par une
    /// reconnexion ou par une revalidation ne l'atteignait pas, et il continuait
    /// d'interroger l'ancienne. Aucune erreur, aucune tâche, et une liaison
    /// pourtant correcte en base.
    ///
    /// Changer de base vide ce qui venait de l'ancienne : ces tâches n'existent
    /// pas dans la nouvelle, et les afficher proposerait de travailler sur des
    /// pages qu'aucune entrée ne pourrait plus référencer.
    public func rebind(dataSourceID: String, mapper: PropertyMapper) {
        self.mapper = mapper
        guard dataSourceID != self.dataSourceID else { return }
        self.dataSourceID = dataSourceID
        tasks = []
        recentUses = [:]
        lastSuccessfulSync = nil
    }

    // MARK: - Rafraîchissement

    /// Recharge la liste. En cas d'échec, le cache précédent reste intact et
    /// consultable : Notion injoignable n'empêche pas de démarrer une session.
    public func refresh() async throws {
        do {
            try await load(filter: queryFilter(), sortingOutDoneHere: false)
        } catch let error as NotionError where error.responseClass == .permanent(.validation) {
            // Notion a refusé le filtre — propriété renommée, valeur de statut
            // disparue, schéma remanié. Une liste vide serait le pire résultat
            // possible : on relit sans filtre et l'on écarte les tâches
            // terminées ici. Mieux vaut une liste complète à trier qu'aucune.
            await log?.log(.error, "filtre refusé par Notion (\(error.message ?? "sans message"))"
                           + " — relecture sans filtre")
            try await load(filter: nil, sortingOutDoneHere: true)
        }
    }

    /// Une lecture complète de la base, page après page.
    ///
    /// Le décompte est journalisé jusque dans ses pertes — reçues, retenues,
    /// écartées faute de titre. Sans lui, une liste amputée par un filtre était
    /// indiscernable d'une base à moitié vide, et c'est exactement ce qui a
    /// coûté deux mises au point.
    private func load(filter: [String: Any]?, sortingOutDoneHere: Bool) async throws {
        var loaded: [CachedTaskItem] = []
        var received = 0
        var untitled = 0
        var done = 0
        var cursor: String?

        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let filter { body["filter"] = filter }
            if let cursor { body["start_cursor"] = cursor }

            let page = try await client.queryDataSource(dataSourceID, body: body)
            received += page.results.count
            for result in page.results {
                guard let item = item(from: result) else { untitled += 1; continue }
                if sortingOutDoneHere && isDone(result) { done += 1; continue }
                loaded.append(item)
            }
            cursor = page.hasMore ? page.nextCursor : nil
        } while cursor != nil

        tasks = loaded
        lastSuccessfulSync = Date()
        await log?.log(.sync, "cache de tâches rafraîchi=\(loaded.count) reçues=\(received)"
                       + " sans-titre=\(untitled) terminées=\(done)"
                       + " filtre=\(filter == nil ? "aucun" : "API")"
                       + " assignées-à-moi-seulement=\(settings.onlyAssignedToMe)"
                       + " source=\(dataSourceID)")
    }

    /// Ce qui empêche de marquer une tâche terminée, quand rien dans le schéma
    /// ne sait exprimer « terminé ».
    public enum CompletionRefusal: Error, Equatable {
        /// Aucune propriété de statut n'est liée dans cette base.
        case noStatusProperty
        /// La propriété existe mais ne déclare aucune valeur « terminé » — un
        /// `select` sans groupes, dont l'utilisateur n'a rien désigné.
        case noDoneValue
    }

    /// Passe une tâche à « terminé » dans Notion, et la retire du cache.
    ///
    /// La valeur écrite vient **du schéma**, jamais du code : c'est la première
    /// option du groupe « terminé » de la base, ou à défaut la première valeur
    /// que l'utilisateur a désignée comme telle. Écrire « Terminé » en dur ne
    /// survivrait pas à une base en anglais, ni à un statut renommé.
    @discardableResult
    public func markDone(_ pageID: String) async throws -> String {
        guard let reference = mapper.reference(.taskStatus) else {
            throw CompletionRefusal.noStatusProperty
        }
        guard let value = TaskCache.doneValues(for: reference,
                                               adding: settings.doneStatusValues).first else {
            throw CompletionRefusal.noDoneValue
        }
        let container = reference.type == "status" ? "status" : "select"
        try await client.updatePage(id: pageID,
                                    properties: [reference.name: [container: ["name": value]]])
        // La tâche n'a plus sa place dans une liste de tâches à faire : elle en
        // sort tout de suite, sans attendre le prochain rafraîchissement.
        tasks.removeAll { $0.id == pageID }
        await log?.log(.sync, "tâche marquée terminée page=\(pageID) "
                       + "propriété=\(reference.name) valeur=\(value)")
        return value
    }

    /// La tâche est-elle terminée ? Sert au repli, quand le tri n'a pas pu être
    /// demandé à l'API.
    private func isDone(_ page: NotionPage) -> Bool {
        guard let reference = mapper.reference(.taskStatus),
              let value = mapper.readStatusValue(.taskStatus, from: page.properties)
        else { return false }
        return TaskCache.doneValues(for: reference, adding: settings.doneStatusValues)
            .contains(value)
    }

    /// Filtre poussé à l'API : statut non terminé, et responsable si demandé.
    ///
    /// Tout ce qui est écarté ici est invisible et sans recours : une clause de
    /// trop, et des tâches parfaitement ouvertes disparaissent du menu sans
    /// message. Chaque clause doit donc pouvoir se justifier ligne à ligne.
    func queryFilter() -> [String: Any]? {
        var clauses: [[String: Any]] = []

        // Un `and` de `does_not_equal` plutôt qu'un `nin` : la propriété peut
        // être un `status` ou un `select`, et le conteneur diffère.
        if let reference = mapper.reference(.taskStatus) {
            let container = reference.type == "status" ? "status" : "select"
            let excluded = TaskCache.doneValues(for: reference,
                                                adding: settings.doneStatusValues)
                .map { value -> [String: Any] in
                    ["property": reference.name, container: ["does_not_equal": value]]
                }
            if !excluded.isEmpty {
                // Une tâche sans statut n'est pas une tâche terminée. Ce que
                // `does_not_equal` fait des valeurs vides n'est pas documenté :
                // on ne s'en remet pas à son interprétation, on garde ces
                // tâches explicitement.
                let notDone: [String: Any] = excluded.count == 1 ? excluded[0]
                                                                 : ["and": excluded]
                clauses.append(["or": [["property": reference.name,
                                        container: ["is_empty": true]],
                                       notDone]])
            }
        }

        // Le filtre Personne n'existe que si l'utilisateur l'a demandé **et**
        // que l'on sait qui il est. La charge OAuth ne porte pas toujours
        // d'utilisateur : l'identifiant valait alors la chaîne vide, et
        // `people.contains("")` ne désigne personne — toutes les tâches
        // assignées disparaissaient.
        if settings.onlyAssignedToMe,
           let reference = mapper.reference(.taskAssignee),
           let user = settings.currentUserID, !user.isEmpty {
            clauses.append(["property": reference.name, "people": ["contains": user]])
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.count == 1 ? clauses[0] : ["and": clauses]
    }

    /// Ce qui compte comme terminé : le groupe « terminé » du schéma, plus les
    /// valeurs ajoutées par l'utilisateur.
    ///
    /// **Filtré par les options réellement déclarées.** Notion rejette la requête
    /// entière — pas seulement la clause fautive — dès qu'une valeur lui est
    /// inconnue : un seul libellé périmé dans les réglages, et plus aucune tâche
    /// ne se charge. Une valeur qui n'existe pas n'a de toute façon aucune tâche
    /// à exclure, la retirer ne change donc rien au résultat.
    static func doneValues(for reference: PropertyRef, adding extra: [String]) -> [String] {
        let declared = Set(reference.options)
        var kept: [String] = []
        for value in reference.completeOptions + extra where !kept.contains(value) {
            guard declared.isEmpty || declared.contains(value) else { continue }
            kept.append(value)
        }
        return kept
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
                              dueDate: TaskDateChoice.date(in: page.properties),
                              searchKey: TaskCache.fold(title))
    }

    // MARK: - Création

    /// Crée une tâche dans la base liée et la place en tête du cache.
    ///
    /// Seul le titre est écrit. Une base de tâches peut porter n'importe quelles
    /// autres propriétés, et deviner ce qu'il faut y mettre — un statut, un
    /// responsable — reviendrait à décider à la place de l'utilisateur. La page
    /// naît donc telle qu'elle naîtrait dans Notion : avec un titre.
    ///
    /// Elle est ajoutée au cache sans attendre le prochain rafraîchissement :
    /// c'est la tâche que l'utilisateur vient d'écrire, elle doit être là.
    public func createTask(titled title: String,
                           projectPageID: String? = nil,
                           due: Date? = nil) async throws -> CachedTaskItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = mapper.titleValue(.taskTitle, trimmed) else {
            // Rien à envoyer : sans propriété de titre connue, la requête ne
            // pourrait porter aucun nom de tâche.
            throw NotionError(responseClass: .permanent(.validation),
                              message: "La propriété de titre de la base Tâches est inconnue.",
                              hadResponse: false)
        }
        var properties: [String: Any] = [value.0: value.1]
        if let projectPageID, let relation = mapper.relationValue(.taskProject, [projectPageID]) {
            properties[relation.0] = relation.1
        }
        if let due, let name = await dueDatePropertyName() {
            properties[name] = ["date": ["start": TaskCache.day.string(from: due)]]
        }

        let body: [String: Any] = ["parent": ["data_source_id": dataSourceID],
                                   "properties": properties]
        let id = try await client.createPage(body)
        let item = CachedTaskItem(id: id, title: trimmed, statusValue: nil, assigneeIDs: [],
                                  projectPageID: projectPageID, dueDate: due,
                                  searchKey: TaskCache.fold(trimmed))
        tasks.removeAll { $0.id == id }
        tasks.insert(item, at: 0)
        await log?.log(.sync, "tâche créée depuis le menu id=\(id)")
        return item
    }

    /// Le nom de la propriété d'échéance de la base, lu une fois.
    ///
    /// Le schéma n'est demandé que si une date est à écrire, et jamais deux
    /// fois : une base ne change pas de colonnes entre deux tâches.
    private func dueDatePropertyName() async -> String? {
        if let dueProperty { return dueProperty }
        guard let source = try? await client.retrieveDataSource(id: dataSourceID) else { return nil }
        let name = TaskDateChoice.writableProperty(in: source.properties)
        dueProperty = .some(name)
        return name
    }

    /// Une échéance est un jour, pas un instant : Notion accepte « 2026-09-12 »
    /// et l'affiche sans heure, ce qui est bien ce qu'on veut dire.
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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
