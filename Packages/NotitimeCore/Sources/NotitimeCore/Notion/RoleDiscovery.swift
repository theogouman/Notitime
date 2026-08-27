import Foundation

/// Candidat proposé à l'utilisateur pour un rôle.
public struct RoleCandidate: Sendable, Equatable {
    public let dataSourceID: String
    public let dataSourceName: String
    public let databaseID: String?
    public let databaseTitle: String
    public let validation: SchemaValidation

    public var isValid: Bool { validation.isValid }
}

/// Une base à plusieurs sources : l'utilisateur tranche, l'application ne choisit
/// pas d'office et n'échoue pas (FR-006a).
public struct SourceChoice: Sendable, Equatable {
    public let databaseID: String
    public let databaseTitle: String
    public let sources: [NotionDataSourceRef]
}

public struct DiscoveryOutcome: Sendable, Equatable {
    /// Rôles assignés automatiquement parce qu'une seule source satisfait le schéma.
    public var assigned: [DatabaseRole: RoleCandidate]
    /// Rôles pour lesquels plusieurs candidats existent ou aucun ne convient.
    public var unresolved: [DatabaseRole: [RoleCandidate]]
    /// Bases dont la pluralité de sources demande un choix explicite.
    public var sourceChoices: [SourceChoice]
}

/// Découverte des rôles.
///
/// L'assignation se fait **par validation de schéma**, jamais par correspondance
/// de titre : les titres sont traduisibles et renommables par l'équipe, le schéma
/// beaucoup moins. C'est ce qui rend automatique le cas du second membre qui
/// partage la page du template existant (SC-007, R-15).
public struct RoleDiscovery: Sendable {

    private let client: NotionClient
    private let validator: SchemaValidator

    public init(client: NotionClient, validator: SchemaValidator = SchemaValidator()) {
        self.client = client
        self.validator = validator
    }

    /// Découverte après duplication du template : page → `child_database` →
    /// sources → schéma → rôle.
    public func discoverFromTemplate(pageID: String) async throws -> DiscoveryOutcome {
        let databaseIDs = try await client.childDatabaseIDs(ofPage: pageID)
        var candidates: [RoleCandidate] = []
        var choices: [SourceChoice] = []

        for databaseID in databaseIDs {
            let database = try await client.retrieveDatabase(id: databaseID)
            if database.dataSources.count > 1 {
                choices.append(SourceChoice(databaseID: database.id,
                                            databaseTitle: database.title,
                                            sources: database.dataSources))
            }
            for reference in database.dataSources {
                let source = try await client.retrieveDataSource(id: reference.id)
                candidates.append(contentsOf: candidatesFor(source,
                                                            databaseTitle: database.title,
                                                            fallbackName: reference.name))
            }
        }

        return resolve(candidates, sourceChoices: choices)
    }

    /// Sans template dupliqué : liste des sources accessibles, pré-sélection par
    /// schéma, l'utilisateur tranchant (FR-005).
    public func discoverFromAccessibleSources() async throws -> DiscoveryOutcome {
        let sources = try await client.searchDataSources()
        let candidates = sources.flatMap {
            candidatesFor($0, databaseTitle: $0.title, fallbackName: $0.title)
        }
        return resolve(candidates, sourceChoices: [])
    }

    private func candidatesFor(_ source: NotionDataSource, databaseTitle: String,
                               fallbackName: String) -> [RoleCandidate] {
        DatabaseRole.allCases.compactMap { role in
            let validation = validator.validate(source, as: role)
            guard validation.isValid else { return nil }
            return RoleCandidate(dataSourceID: source.id,
                                 dataSourceName: source.title.isEmpty ? fallbackName : source.title,
                                 databaseID: source.databaseID,
                                 databaseTitle: databaseTitle,
                                 validation: validation)
        }
    }

    private func resolve(_ candidates: [RoleCandidate],
                         sourceChoices: [SourceChoice]) -> DiscoveryOutcome {
        var byRole: [DatabaseRole: [RoleCandidate]] = [:]
        for role in DatabaseRole.allCases {
            byRole[role] = candidates.filter { validator.validate(forRole: role, candidate: $0) }
        }

        var assigned: [DatabaseRole: RoleCandidate] = [:]
        var unresolved: [DatabaseRole: [RoleCandidate]] = [:]
        var taken = Set<String>()

        // Les rôles les plus contraints d'abord : Time Entries exige neuf
        // propriétés dont deux relations, il ne peut pratiquement pas être
        // confondu, alors que Projets n'exige qu'un titre et matcherait tout.
        for role in [DatabaseRole.timeEntries, .tasks, .projects] {
            let available = (byRole[role] ?? []).filter { !taken.contains($0.dataSourceID) }
            if available.count == 1, let only = available.first {
                assigned[role] = only
                taken.insert(only.dataSourceID)
            } else if !available.isEmpty {
                unresolved[role] = available
            }
        }

        return DiscoveryOutcome(assigned: assigned, unresolved: unresolved,
                                sourceChoices: sourceChoices)
    }
}

private extension SchemaValidator {
    /// Un candidat n'est retenu pour un rôle que si sa validation pour ce rôle
    /// est bonne. `candidatesFor` produit déjà un candidat par rôle valide.
    func validate(forRole role: DatabaseRole, candidate: RoleCandidate) -> Bool {
        SchemaDefinition.required(for: role)
            .filter(\.isRequired)
            .allSatisfy { candidate.validation.propertyMap[$0.key] != nil }
    }
}
