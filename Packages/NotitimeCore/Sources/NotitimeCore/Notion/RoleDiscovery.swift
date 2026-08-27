import Foundation

/// Candidat proposé à l'utilisateur pour un rôle.
public struct RoleCandidate: Sendable, Equatable {
    /// Rôle pour lequel ce candidat a été validé.
    ///
    /// Sans lui, le rôle se redevinait en confrontant le mapping du candidat aux
    /// exigences d'un autre rôle — ce qui ne fonctionnait que parce que les clés
    /// de propriété diffèrent d'un rôle à l'autre. Le porter explicitement rend
    /// l'intention lisible et le filtrage sûr.
    public let role: DatabaseRole
    public let dataSourceID: String
    public let dataSourceName: String
    public let databaseID: String?
    public let databaseTitle: String
    public let validation: SchemaValidation

    public var isValid: Bool { validation.isValid }
}

/// Source accessible, proposée telle quelle pour une désignation manuelle.
///
/// Contrairement à `RoleCandidate`, elle ne présume d'aucun rôle et n'est pas
/// filtrée par le schéma : c'est le recours offert quand la détection
/// automatique n'a rien trouvé. La validation intervient après le choix, et
/// c'est elle qui proposera de créer les propriétés manquantes (FR-006).
public struct AccessibleSource: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let databaseID: String?

    public init(id: String, name: String, databaseID: String?) {
        self.id = id
        self.name = name
        self.databaseID = databaseID
    }
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

    /// La découverte n'a strictement rien remonté.
    ///
    /// C'est un cas distinct d'une découverte incomplète : il n'y a rien à
    /// proposer à l'utilisateur, et l'écran doit alors expliquer et offrir un
    /// recours au lieu de n'afficher qu'un titre (FR-015a).
    public var isEmpty: Bool {
        assigned.isEmpty && unresolved.isEmpty && sourceChoices.isEmpty
    }
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
    private let time: TimeSource
    private let log: SessionLog?

    /// Nombre de lectures de la page dupliquée avant d'abandonner.
    public static let templateAttempts = 5
    /// Attente avant la première nouvelle tentative ; elle double ensuite.
    public static let templateFirstDelay: Duration = .seconds(1)

    public init(client: NotionClient, validator: SchemaValidator = SchemaValidator(),
                time: TimeSource = SystemTimeSource(), log: SessionLog? = nil) {
        self.client = client
        self.validator = validator
        self.time = time
        self.log = log
    }

    /// Découverte après duplication du template : page → `child_database` →
    /// sources → schéma → rôle.
    public func discoverFromTemplate(pageID: String) async throws -> DiscoveryOutcome {
        let databaseIDs = try await templateDatabaseIDs(pageID: pageID)
        await log?.log(.sync, "découverte template page=\(pageID) bases=\(databaseIDs.count)")
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

    /// Lit les bases de la page dupliquée, en tolérant que la copie soit encore
    /// en cours.
    ///
    /// Notion duplique le template de façon **asynchrone** : au retour de l'OAuth
    /// la page peut ne pas encore exister (`404`), ou exister en étant toujours
    /// vide. Une lecture unique remontait alors zéro base, sans rien distinguer
    /// d'un template réellement dépourvu de bases.
    ///
    /// L'attente double à chaque tentative et reste bornée : au bout du budget on
    /// rend une liste vide, à charge pour l'appelant de l'expliquer.
    private func templateDatabaseIDs(pageID: String) async throws -> [String] {
        var delay = RoleDiscovery.templateFirstDelay

        for attempt in 1...RoleDiscovery.templateAttempts {
            do {
                let found = try await client.childDatabaseIDs(ofPage: pageID)
                if !found.isEmpty { return found }
                await log?.log(.sync, "page dupliquée encore vide, tentative \(attempt)")
            } catch let error as NotionError where error.responseClass.isNotFound {
                // La page n'est pas encore visible : c'est attendu pendant la copie.
                await log?.log(.sync, "page dupliquée pas encore visible, tentative \(attempt)")
            }

            guard attempt < RoleDiscovery.templateAttempts else { break }
            try await time.sleep(for: delay)
            delay = delay * 2
        }

        await log?.log(.sync, "page dupliquée toujours vide après \(RoleDiscovery.templateAttempts) tentatives")
        return []
    }

    /// Sans template dupliqué : liste des sources accessibles, pré-sélection par
    /// schéma, l'utilisateur tranchant (FR-005).
    public func discoverFromAccessibleSources() async throws -> DiscoveryOutcome {
        let sources = try await client.searchDataSources()
        await log?.log(.sync, "découverte par recherche sources=\(sources.count)")
        let candidates = sources.flatMap {
            candidatesFor($0, databaseTitle: $0.title, fallbackName: $0.title)
        }
        return resolve(candidates, sourceChoices: [])
    }

    /// Toutes les sources accessibles, sans filtre de schéma, pour la désignation
    /// manuelle proposée quand la détection automatique n'a rien remonté.
    public func allAccessibleSources() async throws -> [AccessibleSource] {
        let sources = try await client.searchDataSources()
        await log?.log(.sync, "sources accessibles pour choix manuel=\(sources.count)")
        return sources.map {
            AccessibleSource(id: $0.id, name: $0.title, databaseID: $0.databaseID)
        }
    }

    private func candidatesFor(_ source: NotionDataSource, databaseTitle: String,
                               fallbackName: String) -> [RoleCandidate] {
        DatabaseRole.allCases.compactMap { role in
            let validation = validator.validate(source, as: role)
            guard validation.isValid else { return nil }
            return RoleCandidate(role: role,
                                 dataSourceID: source.id,
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
            byRole[role] = candidates.filter { $0.role == role }
        }

        var assigned: [DatabaseRole: RoleCandidate] = [:]
        var unresolved: [DatabaseRole: [RoleCandidate]] = [:]
        var taken = Set<String>()

        // Les rôles les plus contraints d'abord : Time Entries exige neuf
        // propriétés dont deux relations, il ne peut pratiquement pas être
        // confondu, alors que Projets n'exige qu'un titre et matcherait tout.
        for role in [DatabaseRole.timeEntries, .tasks, .projects] {
            let available = (byRole[role] ?? []).filter { !taken.contains($0.dataSourceID) }
            guard !available.isEmpty else { continue }

            // Plusieurs sources satisfont souvent un même rôle : la base Projets
            // du template remplit aussi le schéma Tâches — un titre, un statut,
            // une relation. Exiger l'unicité déclarait alors une ambiguïté sur
            // les deux rôles et n'assignait plus rien du tout.
            //
            // On retient donc la source qui satisfait le rôle **le plus
            // complètement**, et on ne s'en remet à l'utilisateur que si deux
            // candidats sont à égalité — là, il y a vraiment de quoi hésiter.
            let best = available.map(\.mappedPropertyCount).max() ?? 0
            let contenders = available.filter { $0.mappedPropertyCount == best }

            if contenders.count == 1, let only = contenders.first {
                assigned[role] = only
                taken.insert(only.dataSourceID)
            } else {
                unresolved[role] = contenders
            }
        }

        return DiscoveryOutcome(assigned: assigned, unresolved: unresolved,
                                sourceChoices: sourceChoices)
    }
}

extension RoleCandidate {
    /// Nombre de propriétés du rôle que cette source sait fournir.
    ///
    /// Mesure de spécificité : entre deux sources valides pour un même rôle,
    /// celle qui en couvre le plus est la bonne.
    var mappedPropertyCount: Int { validation.propertyMap.count }
}
