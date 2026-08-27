import Foundation

// Objets Notion décodés. On ne décode que ce dont l'application se sert :
// la surface consommée est close (`contracts/notion-api.md`).

/// Types de propriétés Notion manipulés par l'application.
public enum NotionPropertyType: String, Codable, Sendable {
    case title, richText = "rich_text", date, number, select, status, people, relation
    case formula, uniqueID = "unique_id", rollup, checkbox, url, email, phoneNumber = "phone_number"
    case multiSelect = "multi_select", files, createdTime = "created_time"
    case lastEditedTime = "last_edited_time", createdBy = "created_by"
    case lastEditedBy = "last_edited_by", other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotionPropertyType(rawValue: raw) ?? .other
    }
}

/// Descripteur d'une propriété tel que Notion le renvoie dans un schéma.
public struct NotionPropertySchema: Codable, Sendable {
    public let id: String
    public let name: String
    public let type: NotionPropertyType

    public var reference: PropertyRef {
        PropertyRef(id: id, name: name, type: type.rawValue)
    }
}

/// Une source de données : porte le schéma, s'interroge, reçoit les pages.
public struct NotionDataSource: Sendable {
    public let id: String
    public let title: String
    public let properties: [String: NotionPropertySchema]
    /// Base conteneur, via `parent.database_id`.
    public let databaseID: String?

    public init(id: String, title: String, properties: [String: NotionPropertySchema], databaseID: String?) {
        self.id = id
        self.title = title
        self.properties = properties
        self.databaseID = databaseID
    }
}

extension NotionDataSource: Decodable {
    private enum CodingKeys: String, CodingKey { case id, title, properties, parent }
    private struct Parent: Decodable { let type: String?; let databaseID: String?
        private enum CodingKeys: String, CodingKey { case type, databaseID = "database_id" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            databaseID = try c.decodeIfPresent(String.self, forKey: .databaseID)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let richText = try container.decodeIfPresent([NotionRichText].self, forKey: .title) ?? []
        title = NotionRichText.plainText(richText)
        properties = try container.decodeIfPresent([String: NotionPropertySchema].self, forKey: .properties) ?? [:]
        databaseID = try container.decodeIfPresent(Parent.self, forKey: .parent)?.databaseID
    }
}

/// Élément de `data_sources[]` renvoyé par la lecture d'une base.
public struct NotionDataSourceRef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Réponse de `GET /v1/databases/{id}` : le conteneur et ses sources.
public struct NotionDatabase: Sendable {
    public let id: String
    public let title: String
    public let dataSources: [NotionDataSourceRef]

    public init(id: String, title: String, dataSources: [NotionDataSourceRef]) {
        self.id = id
        self.title = title
        self.dataSources = dataSources
    }
}

extension NotionDatabase: Decodable {
    private enum CodingKeys: String, CodingKey { case id, title, dataSources = "data_sources" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let richText = try container.decodeIfPresent([NotionRichText].self, forKey: .title) ?? []
        title = NotionRichText.plainText(richText)
        dataSources = try container.decodeIfPresent([NotionDataSourceRef].self, forKey: .dataSources) ?? []
    }
}

public struct NotionRichText: Decodable, Sendable {
    public let plainText: String
    private enum CodingKeys: String, CodingKey { case plainText = "plain_text" }

    static func plainText(_ items: [NotionRichText]) -> String {
        items.map(\.plainText).joined()
    }
}

/// Bloc enfant d'une page. Seuls les `child_database` intéressent la découverte,
/// mais il faut traverser les conteneurs de mise en page pour les atteindre.
public struct NotionBlock: Decodable, Sendable {
    public let id: String
    public let type: String
    public let hasChildren: Bool

    private enum CodingKeys: String, CodingKey { case id, type, hasChildren = "has_children" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        hasChildren = try container.decodeIfPresent(Bool.self, forKey: .hasChildren) ?? false
    }

    public init(id: String, type: String, hasChildren: Bool) {
        self.id = id
        self.type = type
        self.hasChildren = hasChildren
    }

    public var isChildDatabase: Bool { type == "child_database" }

    public var isChildPage: Bool { type == "child_page" }

    /// Bloc dans lequel la descente continue.
    ///
    /// Les sous-pages en font partie : un template range couramment ses bases
    /// dans une page « Template » nichée sous un encart, et s'arrêter à la
    /// première sous-page ne remontait alors aucune base. L'exploration part
    /// toujours de la page dupliquée et Notion ne permet pas de remonter vers le
    /// parent : elle reste donc dans le sous-arbre du template, et la borne de
    /// profondeur la termine.
    ///
    /// Une base est exclue : ses enfants sont ses lignes, pas des blocs.
    public var shouldDescend: Bool {
        hasChildren && !isChildDatabase
    }
}

public struct NotionList<Element: Decodable & Sendable>: Decodable, Sendable {
    public let results: [Element]
    public let hasMore: Bool
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case results, hasMore = "has_more", nextCursor = "next_cursor"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([Element].self, forKey: .results)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// Charge utile d'autorisation, relayée telle quelle par le backend.
public struct NotionAuthorization: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let botID: String
    public let workspaceID: String
    public let workspaceName: String?
    public let workspaceIcon: String?
    public let duplicatedTemplateID: String?
    public let owner: Owner?

    public struct Owner: Decodable, Sendable {
        public let user: User?
        public struct User: Decodable, Sendable {
            public let id: String
            public let name: String?
        }
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case botID = "bot_id", workspaceID = "workspace_id"
        case workspaceName = "workspace_name", workspaceIcon = "workspace_icon"
        case duplicatedTemplateID = "duplicated_template_id", owner
    }
}

/// Corps d'erreur OAuth ou API.
public struct NotionErrorBody: Decodable, Sendable {
    public let error: String?
    public let code: String?
    public let message: String?
}
