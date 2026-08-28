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
    /// Options déclarées, pour un `select` ou un `status`.
    public let options: [String]
    /// Options du groupe « terminé » d'un `status`, dans l'ordre du schéma.
    ///
    /// C'est le schéma qui dit ce qu'« être terminé » veut dire dans cette base :
    /// « Terminé » et « Annulé » ici, autre chose ailleurs. Un `select` n'a pas
    /// de groupes et rend donc une liste vide.
    public let completeOptions: [String]

    public var reference: PropertyRef {
        PropertyRef(id: id, name: name, type: type.rawValue,
                    options: options, completeOptions: completeOptions)
    }

    public init(id: String, name: String, type: NotionPropertyType,
                options: [String] = [], completeOptions: [String] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.options = options
        self.completeOptions = completeOptions
    }

    private enum CodingKeys: String, CodingKey { case id, name, type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(NotionPropertyType.self, forKey: .type)

        // Les options vivent sous une clé qui porte le nom du type — `select`
        // ou `status` —, et un `status` les groupe en plus par avancement.
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        if let key = DynamicKey(stringValue: type.rawValue),
           let holder = try? dynamic.decode(OptionHolder.self, forKey: key) {
            let declared = holder.options ?? []
            options = declared.map(\.name)
            completeOptions = NotionPropertySchema.complete(of: holder.groups, among: declared)
        } else {
            options = []
            completeOptions = []
        }
    }

    /// Retrouve le groupe « terminé » parmi les trois groupes d'un `status`.
    ///
    /// Deux voies, dans cet ordre. Le nom d'abord, parce qu'il est explicite —
    /// mais il est renommable dans l'interface Notion et n'est pas traduit de
    /// façon prévisible, donc il ne peut pas être le seul recours. La position
    /// ensuite : Notion impose exactement trois groupes, dans l'ordre à faire,
    /// en cours, terminé, et l'API ne permet ni d'en ajouter ni de les réordonner.
    static func complete(of groups: [OptionHolder.Group]?,
                         among options: [OptionHolder.Option]) -> [String] {
        guard let groups, !groups.isEmpty else { return [] }
        let hints = ["complete", "complété", "complet", "terminé", "termine",
                     "fini", "achevé", "done", "closed"]

        let chosen = groups.first { group in
            hints.contains { group.name.containsFolded($0) }
        } ?? (groups.count == 3 ? groups.last : nil)

        guard let chosen else { return [] }
        let names = Dictionary(options.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return chosen.optionIDs.compactMap { names[$0] }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    struct OptionHolder: Decodable {
        struct Option: Decodable { let id: String; let name: String }
        struct Group: Decodable {
            let name: String
            let optionIDs: [String]
            private enum CodingKeys: String, CodingKey { case name, optionIDs = "option_ids" }
        }
        let options: [Option]?
        let groups: [Group]?
    }
}

/// Un modèle de page déclaré sur une source de données.
public struct NotionTemplate: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    private enum CodingKeys: String, CodingKey { case id, name, isDefault = "is_default" }

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// Réponse de `GET /v1/data_sources/{id}/templates`.
///
/// Cet endpoint **ne suit pas** l'enveloppe de liste habituelle : les éléments
/// sont sous `templates`, non sous `results`, et il n'y a pas de champ `object`.
/// Le décoder comme une liste ordinaire échouait sur `results` absent, et
/// l'échec passait pour une base sans modèle — les entrées naissaient nues.
public struct NotionTemplateList: Decodable, Sendable {
    public let templates: [NotionTemplate]
    public let hasMore: Bool
    public let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case templates, hasMore = "has_more", nextCursor = "next_cursor"
    }

    public init(templates: [NotionTemplate], hasMore: Bool = false, nextCursor: String? = nil) {
        self.templates = templates
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        templates = try container.decodeIfPresent([NotionTemplate].self, forKey: .templates) ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
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

    public init(results: [Element], hasMore: Bool, nextCursor: String?) {
        self.results = results
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }

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

/// Réponse de `POST /v1/pages` : seul l'identifiant nous intéresse — il prouve
/// la création et sert de parent au commentaire.
public struct NotionCreatedPage: Decodable, Sendable {
    public let id: String
}

/// Réponse de `POST /v1/comments`. Le corps n'est pas exploité : la publication
/// est best-effort, seul son succès compte (FR-026a).
public struct NotionCreatedComment: Decodable, Sendable {
    public let id: String?
}

/// Une page Notion telle que renvoyée par l'interrogation d'une source.
///
/// `properties` reste un dictionnaire non typé : c'est `PropertyMapper` qui en
/// extrait des valeurs, le schéma variant d'un workspace à l'autre.
public struct NotionPage: Decodable, Sendable {
    public let id: String
    public let properties: [String: Any]
    /// Les pages en corbeille ne doivent jamais être proposées (FR-009).
    public let inTrash: Bool

    private enum CodingKeys: String, CodingKey {
        case id, properties, inTrash = "in_trash"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        inTrash = try container.decodeIfPresent(Bool.self, forKey: .inTrash) ?? false
        let raw = try container.decodeIfPresent(JSONValue.self, forKey: .properties)
        properties = (raw?.unwrapped as? [String: Any]) ?? [:]
    }
}

/// Valeur JSON quelconque, pour les blocs dont le schéma varie d'un workspace à
/// l'autre — le `properties` d'une page.
///
/// `Decodable` n'accepte pas `Any` directement ; ce type sert de passerelle vers
/// les dictionnaires non typés que `PropertyMapper` sait lire.
enum JSONValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "valeur JSON non reconnue")
        }
    }

    var unwrapped: Any? {
        switch self {
        case .null: return nil
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map { $0.unwrapped as Any }
        case .object(let values): return values.compactMapValues { $0.unwrapped }
        }
    }
}
