import Foundation

/// Résultat de la validation d'une source pour un rôle.
public enum SchemaValidation: Equatable, Sendable {
    case valid(propertyMap: [PropertyKey: PropertyRef])
    /// Propriétés requises absentes ou de mauvais type. `creatable` liste celles
    /// que l'application sait proposer de créer (FR-006).
    case missing(properties: [PropertyKey], creatable: [PropertyKey],
                 propertyMap: [PropertyKey: PropertyRef])

    public var isValid: Bool { if case .valid = self { return true }; return false }

    public var propertyMap: [PropertyKey: PropertyRef] {
        switch self {
        case .valid(let map), .missing(_, _, let map): return map
        }
    }
}

/// Valide une source contre le schéma attendu et construit le mapping.
///
/// La correspondance se fait sur le **type** avant le nom : une base renommée par
/// l'équipe reste reconnaissable, ce que la spec liste explicitement comme cas
/// limite. Le nom par défaut ne sert qu'à départager plusieurs candidats.
public struct SchemaValidator: Sendable {

    public init() {}

    public func validate(_ dataSource: NotionDataSource, as role: DatabaseRole,
                         existingMap: [PropertyKey: PropertyRef] = [:]) -> SchemaValidation {
        var map: [PropertyKey: PropertyRef] = [:]
        var missing: [PropertyKey] = []
        var creatable: [PropertyKey] = []
        var consumed = Set<String>()

        for requirement in SchemaDefinition.required(for: role) {
            if let pinned = existingMap[requirement.key],
               let schema = dataSource.properties.values.first(where: { $0.id == pinned.id }),
               requirement.acceptedTypes.contains(schema.type) {
                map[requirement.key] = schema.reference
                consumed.insert(schema.id)
                continue
            }

            let candidates = dataSource.properties.values
                .filter { requirement.acceptedTypes.contains($0.type) && !consumed.contains($0.id) }

            // Nom exact d'abord, puis insensible à la casse, puis n'importe quel
            // candidat du bon type s'il est seul : au-delà, on préfère demander.
            let chosen = candidates.first { $0.name == requirement.defaultName }
                ?? candidates.first { $0.name.compare(requirement.defaultName,
                                                      options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                ?? (candidates.count == 1 ? candidates.first : nil)

            if let chosen {
                map[requirement.key] = chosen.reference
                consumed.insert(chosen.id)
            } else if requirement.isRequired {
                missing.append(requirement.key)
                if SchemaDefinition.creationPayload(for: requirement) != nil {
                    creatable.append(requirement.key)
                }
            }
        }

        return missing.isEmpty
            ? .valid(propertyMap: map)
            : .missing(properties: missing, creatable: creatable, propertyMap: map)
    }

    /// Charge utile de création des propriétés manquantes que l'app sait créer.
    /// Ce qu'elle ne sait pas créer reste à l'utilisateur — on ne devine pas la
    /// source cible d'une relation.
    public func creationPayload(for keys: [PropertyKey], role: DatabaseRole) -> [String: Any] {
        var payload: [String: Any] = [:]
        for requirement in SchemaDefinition.required(for: role) where keys.contains(requirement.key) {
            if let body = SchemaDefinition.creationPayload(for: requirement) {
                payload[requirement.defaultName] = body
            }
        }
        return payload
    }
}
