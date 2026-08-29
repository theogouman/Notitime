import Foundation

/// Un projet, tel qu'on le choisit dans une liste.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Tout ce que la page donne à lire, replié — titre, textes, options,
    /// nombres, dates. C'est ce qui permet de retrouver un projet par un mot
    /// qui ne figure pas dans son nom.
    public let searchKey: String

    public init(id: String, name: String, searchKey: String) {
        self.id = id
        self.name = name
        self.searchKey = searchKey
    }

    public func matches(_ needle: String) -> Bool {
        needle.isEmpty || searchKey.contains(needle)
    }
}

/// La liste des projets, les plus récemment actifs en tête.
///
/// L'ordre vient de Notion, trié sur la dernière modification : c'est la
/// meilleure approximation disponible de « ce sur quoi on travaille en ce
/// moment ». Notion n'expose aucune mesure d'activité — ni nombre d'éditions,
/// ni fréquence —, et la reconstituer supposerait de lire l'historique de
/// chaque page, une requête par projet. La date de dernière modification dit
/// l'essentiel pour une seule requête.
public struct ProjectDirectory: Sendable {

    /// Garde-fou : cinq pages, soit cinq cents projets. Au-delà, la liste ne se
    /// parcourt plus à l'œil et la recherche prend le relais.
    public static let pageLimit = 5

    private let client: NotionClient
    private let mapper: PropertyMapper
    private let log: SessionLog?

    public init(client: NotionClient, mapper: PropertyMapper, log: SessionLog? = nil) {
        self.client = client
        self.mapper = mapper
        self.log = log
    }

    public func load(from dataSourceID: String) async throws -> [ProjectSummary] {
        var projects: [ProjectSummary] = []
        var cursor: String?
        var pages = 0

        repeat {
            var body: [String: Any] = [
                "page_size": 100,
                // Le tri est fait par Notion : trier ici obligerait à tout
                // rapatrier avant d'afficher la première ligne.
                "sorts": [["timestamp": "last_edited_time", "direction": "descending"]]
            ]
            if let cursor { body["start_cursor"] = cursor }

            let page = try await client.queryDataSource(dataSourceID, body: body)
            projects.append(contentsOf: page.results.compactMap(summary(from:)))
            cursor = page.hasMore ? page.nextCursor : nil
            pages += 1
            if pages >= ProjectDirectory.pageLimit { break }
        } while cursor != nil

        await log?.log(.sync, "projets chargés=\(projects.count)")
        return projects
    }

    private func summary(from page: NotionPage) -> ProjectSummary? {
        let title = mapper.readTitle(.projectTitle, from: page.properties)
            ?? PropertyText.title(in: page.properties)
        guard let title, !title.isEmpty else { return nil }
        let text = title + " " + PropertyText.flatten(page.properties)
        return ProjectSummary(id: page.id, name: title, searchKey: TaskCache.fold(text))
    }
}

/// Le texte lisible d'un bloc `properties`, tous types confondus.
///
/// Sert à chercher « par mots-clés » sans savoir à l'avance quelles propriétés
/// une base porte : c'est la base de l'utilisateur, pas la nôtre.
public enum PropertyText {

    /// Le titre d'une page, quel que soit le nom de sa propriété de titre.
    public static func title(in properties: [String: Any]) -> String? {
        for value in properties.values {
            guard let property = value as? [String: Any],
                  property["type"] as? String == "title",
                  let items = property["title"] as? [[String: Any]] else { continue }
            let text = items.compactMap { $0["plain_text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        return nil
    }

    public static func flatten(_ properties: [String: Any]) -> String {
        var parts: [String] = []
        for (name, value) in properties {
            guard let property = value as? [String: Any],
                  let type = property["type"] as? String else { continue }
            // Le nom de la propriété compte lui aussi : « Client » retrouve les
            // projets qui en portent un, quel qu'il soit.
            switch type {
            case "title", "rich_text":
                let items = property[type] as? [[String: Any]] ?? []
                parts.append(items.compactMap { $0["plain_text"] as? String }.joined())
            case "select", "status":
                if let option = property[type] as? [String: Any],
                   let optionName = option["name"] as? String { parts.append(optionName) }
            case "multi_select":
                let options = property[type] as? [[String: Any]] ?? []
                parts.append(contentsOf: options.compactMap { $0["name"] as? String })
            case "number":
                if let number = property[type] as? NSNumber { parts.append(number.stringValue) }
            case "url", "email", "phone_number":
                if let text = property[type] as? String { parts.append(text) }
            case "date":
                if let date = property[type] as? [String: Any],
                   let start = date["start"] as? String { parts.append(start) }
            case "checkbox":
                if property[type] as? Bool == true { parts.append(name) }
            default:
                // Formules, rollups, relations, personnes : leur contenu n'est
                // pas du texte, ou il désigne d'autres pages. Le nom de la
                // propriété reste utile comme mot-clé.
                parts.append(name)
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
