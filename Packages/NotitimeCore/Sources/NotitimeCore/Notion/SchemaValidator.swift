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

            let candidates = SchemaValidator.ranked(
                dataSource.properties.values
                    .filter { requirement.acceptedTypes.contains($0.type) && !consumed.contains($0.id) },
                for: requirement
            )

            // Du plus sûr au plus permissif. L'ordre compte : chaque étape ne
            // s'applique qu'à ce que la précédente n'a pas su trancher.
            let chosen = candidates.first { $0.name == requirement.defaultName }
                ?? candidates.first { $0.name.compare(requirement.defaultName,
                                                      options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                // Fragment de nom : « Date de début » pour « Début », « Status »
                // pour « Statut ». C'est ce qui manquait face au template réel.
                ?? SchemaValidator.matchingHint(requirement, among: candidates)
                ?? (candidates.count == 1 ? candidates.first : nil)
                // Dernier recours : un seul candidat du type le plus attendu.
                // Un `status` l'emporte alors sur un `select` pour un statut.
                ?? SchemaValidator.onlyOfPreferredType(requirement, among: candidates)

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

    // MARK: - Départage

    /// Ordonne les candidats : type le plus attendu d'abord, puis par nom.
    ///
    /// `properties` est un dictionnaire — son ordre d'itération n'est pas
    /// stable. Sans ce classement, deux exécutions pourraient mapper deux
    /// propriétés interchangeables différemment, et le mapping persisté
    /// changerait d'un lancement à l'autre.
    static func ranked(_ candidates: some Collection<NotionPropertySchema>,
                       for requirement: RequiredProperty) -> [NotionPropertySchema] {
        candidates.sorted { left, right in
            let leftRank = requirement.acceptedTypes.firstIndex(of: left.type) ?? .max
            let rightRank = requirement.acceptedTypes.firstIndex(of: right.type) ?? .max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// Premier candidat dont le nom contient l'un des fragments attendus, les
    /// fragments étant essayés dans l'ordre de préférence.
    static func matchingHint(_ requirement: RequiredProperty,
                             among candidates: [NotionPropertySchema]) -> NotionPropertySchema? {
        for hint in requirement.nameHints {
            if let match = candidates.first(where: { $0.name.containsFolded(hint) }) {
                return match
            }
        }
        return nil
    }

    /// Un seul candidat du type le plus attendu : le retenir plutôt que de
    /// renoncer parce qu'un type moins probable est également présent.
    static func onlyOfPreferredType(_ requirement: RequiredProperty,
                                    among candidates: [NotionPropertySchema]) -> NotionPropertySchema? {
        for type in requirement.acceptedTypes {
            let ofType = candidates.filter { $0.type == type }
            if ofType.count == 1 { return ofType.first }
        }
        return nil
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

extension String {
    /// Comparaison de fragment insensible à la casse **et aux accents** :
    /// « Durée en min » doit répondre à « duree » comme à « durée ».
    func containsFolded(_ fragment: String) -> Bool {
        range(of: fragment, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
