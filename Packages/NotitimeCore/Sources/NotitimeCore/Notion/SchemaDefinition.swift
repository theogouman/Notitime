import Foundation

/// Clés logiques des propriétés. Le mapping traduit une clé en propriété réelle :
/// l'application ne code jamais un nom de propriété en dur (entité Configuration
/// des bases). Les noms par défaut ne servent qu'à la pré-sélection.
public enum PropertyKey: String, Codable, Sendable, CaseIterable {
    // Tâches
    case taskTitle, taskStatus, taskAssignee, taskProject
    // Time Entries
    case entryTitle, entryTask, entryStart, entryEnd, entryDuration
    case entryType, entryStatus, entryPerson, entryLocalID
    // Projets
    case projectTitle
}

/// Une propriété attendue par le schéma.
public struct RequiredProperty: Sendable, Equatable {
    public let key: PropertyKey
    public let defaultName: String
    public let acceptedTypes: [NotionPropertyType]
    public let isRequired: Bool
    /// `nil` quand la propriété ne peut pas être créée par l'application
    /// (un `title` existe toujours ; une relation exige la source cible).
    public let creationType: NotionPropertyType?

    public var displayName: String { defaultName }
}

/// Schéma attendu de chaque rôle, source unique de la validation (FR-006) et de
/// la proposition de création. Reflété dans `docs/notion-schema.md`.
public enum SchemaDefinition {

    public static func required(for role: DatabaseRole) -> [RequiredProperty] {
        switch role {
        case .tasks: return tasks
        case .timeEntries: return timeEntries
        case .projects: return projects
        }
    }

    static let tasks: [RequiredProperty] = [
        RequiredProperty(key: .taskTitle, defaultName: "Nom",
                         acceptedTypes: [.title], isRequired: true, creationType: nil),
        RequiredProperty(key: .taskStatus, defaultName: "Statut",
                         acceptedTypes: [.status, .select], isRequired: true, creationType: .select),
        RequiredProperty(key: .taskAssignee, defaultName: "Personne",
                         acceptedTypes: [.people], isRequired: false, creationType: .people),
        RequiredProperty(key: .taskProject, defaultName: "Projet",
                         acceptedTypes: [.relation], isRequired: false, creationType: nil)
    ]

    static let timeEntries: [RequiredProperty] = [
        RequiredProperty(key: .entryTitle, defaultName: "Nom",
                         acceptedTypes: [.title], isRequired: true, creationType: nil),
        RequiredProperty(key: .entryTask, defaultName: "Tâche",
                         acceptedTypes: [.relation], isRequired: true, creationType: nil),
        RequiredProperty(key: .entryStart, defaultName: "Début",
                         acceptedTypes: [.date], isRequired: true, creationType: .date),
        RequiredProperty(key: .entryEnd, defaultName: "Fin",
                         acceptedTypes: [.date], isRequired: true, creationType: .date),
        RequiredProperty(key: .entryDuration, defaultName: "Durée",
                         acceptedTypes: [.number], isRequired: true, creationType: .number),
        RequiredProperty(key: .entryType, defaultName: "Type",
                         acceptedTypes: [.select], isRequired: true, creationType: .select),
        RequiredProperty(key: .entryStatus, defaultName: "Statut",
                         acceptedTypes: [.select], isRequired: true, creationType: .select),
        RequiredProperty(key: .entryPerson, defaultName: "Personne",
                         acceptedTypes: [.people], isRequired: true, creationType: .people),
        // Type rich text obligatoire : la valeur est générée par l'application
        // AVANT l'envoi. Une formule ou l'identifiant auto-incrémenté de Notion
        // n'existent qu'après création — trop tard pour dédupliquer (FR-028).
        RequiredProperty(key: .entryLocalID, defaultName: NotionAPI.defaultLocalIDPropertyName,
                         acceptedTypes: [.richText], isRequired: true, creationType: .richText)
    ]

    static let projects: [RequiredProperty] = [
        RequiredProperty(key: .projectTitle, defaultName: "Nom",
                         acceptedTypes: [.title], isRequired: true, creationType: nil)
    ]

    /// Valeurs de la propriété Type des entrées de temps.
    public static let entryTypeOptions = ["Pomodoro", "Tracker"]
    /// Valeurs de la propriété Statut des entrées de temps (FR-019, FR-026).
    public static let entryStatusOptions = ["Complété", "Écourté"]

    /// Charge utile de création d'une propriété, pour `PATCH /v1/data_sources/{id}`.
    public static func creationPayload(for property: RequiredProperty) -> [String: Any]? {
        guard let type = property.creationType else { return nil }
        switch type {
        case .richText: return ["rich_text": [:]]
        case .date: return ["date": [:]]
        case .people: return ["people": [:]]
        case .number: return ["number": ["format": "number"]]
        case .select:
            let options: [String]
            switch property.key {
            case .entryType: options = entryTypeOptions
            case .entryStatus: options = entryStatusOptions
            default: options = []
            }
            return ["select": ["options": options.map { ["name": $0] }]]
        default: return nil
        }
    }
}
