import Foundation

/// Tâche telle que le menu la présente.
public struct FetchedTask: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let statusValue: String?
    public let assigneeIDs: [String]
    public let projectPageID: String?

    public init(id: String, title: String, statusValue: String?,
                assigneeIDs: [String], projectPageID: String?) {
        self.id = id
        self.title = title
        self.statusValue = statusValue
        self.assigneeIDs = assigneeIDs
        self.projectPageID = projectPageID
    }
}

/// T055 — chargement minimal des tâches pour l'US2.
///
/// Volontairement sommaire : ni filtre Personne, ni recherche, ni cache. C'est
/// `TaskCache` (US3) qui apportera tout cela ; ici on veut seulement de quoi
/// choisir une tâche et démarrer un pomodoro.
///
/// La pagination est suivie jusqu'au bout, sans plafond : une base de tâches
/// tronquée ferait disparaître du menu des tâches parfaitement valides.
public struct TaskFetch: Sendable {

    /// Notion plafonne à 100 résultats par page.
    public static let pageSize = 100
    /// Garde-fou : au-delà, la base interrogée n'est probablement pas celle des
    /// tâches. Le journal le signale plutôt que de paginer sans fin.
    public static let pageLimit = 50

    private let client: NotionClient
    private let mapper: PropertyMapper
    private let log: SessionLog?

    public init(client: NotionClient, mapper: PropertyMapper, log: SessionLog? = nil) {
        self.client = client
        self.mapper = mapper
        self.log = log
    }

    public func load(from dataSourceID: String) async throws -> [FetchedTask] {
        var tasks: [FetchedTask] = []
        var cursor: String?
        var pages = 0

        repeat {
            var body: [String: Any] = ["page_size": TaskFetch.pageSize]
            if let cursor { body["start_cursor"] = cursor }

            let page = try await client.queryDataSource(dataSourceID, body: body)
            tasks.append(contentsOf: page.results.compactMap(task(from:)))
            cursor = page.hasMore ? page.nextCursor : nil
            pages += 1

            if pages >= TaskFetch.pageLimit, cursor != nil {
                await log?.log(.sync, "chargement des tâches interrompu après "
                               + "\(TaskFetch.pageLimit) pages — liste probablement tronquée")
                break
            }
        } while cursor != nil

        await log?.log(.sync, "tâches chargées=\(tasks.count) source=\(dataSourceID)")
        return tasks
    }

    private func task(from page: NotionPage) -> FetchedTask? {
        // Une page sans titre exploitable ne peut pas être proposée au choix :
        // l'utilisateur ne saurait pas ce qu'il sélectionne.
        guard let title = mapper.readTitle(.taskTitle, from: page.properties), !title.isEmpty
        else { return nil }

        return FetchedTask(id: page.id,
                           title: title,
                           statusValue: mapper.readStatusValue(.taskStatus, from: page.properties),
                           assigneeIDs: mapper.readPeopleIDs(.taskAssignee, from: page.properties),
                           projectPageID: mapper.readRelationIDs(.taskProject,
                                                                 from: page.properties).first)
    }
}
