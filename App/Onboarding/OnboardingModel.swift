import Foundation
import SwiftData
import NotitimeCore

/// Orchestration de la connexion et de l'assignation des rôles.
@MainActor
final class OnboardingModel: ObservableObject {

    enum Step: Equatable {
        case disconnected
        case connecting
        case discovering
        /// Tout est résolu : l'utilisateur voit son workspace et ses rôles.
        case ready
        /// Des rôles restent à assigner, ou une base porte plusieurs sources.
        case needsAssignment
        case failed(String)
    }

    @Published private(set) var step: Step = .disconnected
    @Published private(set) var outcome: DiscoveryOutcome?
    @Published private(set) var workspaceName: String = ""
    @Published private(set) var ownerName: String = ""
    /// Propriétés manquantes par rôle, avec ce que l'app sait créer (FR-006).
    @Published private(set) var missingByRole: [DatabaseRole: [PropertyKey]] = [:]

    private let environment: AppEnvironment
    private let flow = OAuthFlow()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Connexion

    func connect() async {
        step = .connecting
        do {
            let (callback, verifier) = try await flow.authorize()
            let authorization = try await environment.connection.connect(
                code: callback.code, state: callback.state, verifier: verifier
            )
            workspaceName = authorization.workspaceName ?? ""
            ownerName = authorization.owner?.user?.name ?? ""
            persist(authorization)
            await discover(templateID: authorization.duplicatedTemplateID)
        } catch OAuthFlow.FlowError.userCancelled {
            // US1.4 : une annulation n'est pas une erreur technique. On revient
            // simplement à l'état déconnecté, sans message alarmant.
            step = .disconnected
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        do {
            try await environment.connection.disconnect()
            step = .disconnected
            outcome = nil
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    // MARK: - Découverte

    private func discover(templateID: String?) async {
        step = .discovering
        let discovery = RoleDiscovery(client: environment.notion)
        do {
            let result: DiscoveryOutcome
            if let templateID, !templateID.isEmpty {
                // FR-004 : le template dupliqué se découvre tout seul.
                result = try await discovery.discoverFromTemplate(pageID: templateID)
            } else {
                // FR-005 : sinon, on liste et on pré-sélectionne.
                result = try await discovery.discoverFromAccessibleSources()
            }
            outcome = result
            persist(result)
            let complete = result.assigned[.tasks] != nil
                && result.assigned[.timeEntries] != nil
                && result.sourceChoices.isEmpty
            step = complete ? .ready : .needsAssignment
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    /// Assignation manuelle d'une source à un rôle (FR-005, FR-006a).
    func assign(dataSourceID: String, databaseID: String?, name: String, to role: DatabaseRole) async {
        do {
            let source = try await environment.notion.retrieveDataSource(id: dataSourceID)
            let validation = SchemaValidator().validate(source, as: role)
            switch validation {
            case .valid(let map):
                missingByRole[role] = nil
                save(role: role, source: source, name: name,
                     databaseID: databaseID ?? source.databaseID, map: map)
                step = .ready
            case .missing(let missing, _, _):
                // FR-006 : la configuration est refusée tant que le schéma n'est
                // pas valide ; on affiche ce qui manque et on propose de créer.
                missingByRole[role] = missing
                step = .needsAssignment
            }
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    /// Création des propriétés manquantes, sur acceptation explicite (FR-006).
    func createMissingProperties(for role: DatabaseRole, dataSourceID: String) async {
        guard let missing = missingByRole[role], !missing.isEmpty else { return }
        do {
            let payload = SchemaValidator().creationPayload(for: missing, role: role)
            try await environment.notion.addProperties(payload, toDataSource: dataSourceID)
            await assign(dataSourceID: dataSourceID, databaseID: nil, name: "", to: role)
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    // MARK: - Persistance

    private func persist(_ authorization: NotionAuthorization) {
        let context = environment.container.mainContext
        try? context.delete(model: NotionConnection.self)
        context.insert(NotionConnection(
            workspaceID: authorization.workspaceID,
            workspaceName: authorization.workspaceName ?? "",
            workspaceIconURL: authorization.workspaceIcon.flatMap(URL.init(string:)),
            botID: authorization.botID,
            ownerUserID: authorization.owner?.user?.id ?? "",
            ownerName: authorization.owner?.user?.name ?? "",
            duplicatedTemplateID: authorization.duplicatedTemplateID,
            connectedAt: Date()
        ))
        try? context.save()
    }

    private func persist(_ result: DiscoveryOutcome) {
        for (role, candidate) in result.assigned {
            save(role: role,
                 dataSourceID: candidate.dataSourceID,
                 dataSourceName: candidate.dataSourceName,
                 databaseID: candidate.databaseID ?? "",
                 title: candidate.databaseTitle,
                 map: candidate.validation.propertyMap)
        }
    }

    private func save(role: DatabaseRole, source: NotionDataSource, name: String,
                      databaseID: String?, map: [PropertyKey: PropertyRef]) {
        save(role: role, dataSourceID: source.id,
             dataSourceName: name.isEmpty ? source.title : name,
             databaseID: databaseID ?? "", title: source.title, map: map)
    }

    private func save(role: DatabaseRole, dataSourceID: String, dataSourceName: String,
                      databaseID: String, title: String, map: [PropertyKey: PropertyRef]) {
        let context = environment.container.mainContext
        let raw = role.rawValue
        let existing = try? context.fetch(
            FetchDescriptor<DatabaseBinding>(predicate: #Predicate { $0.roleRaw == raw })
        )
        existing?.forEach(context.delete)

        let binding = DatabaseBinding(role: role, databaseID: databaseID,
                                      dataSourceID: dataSourceID, dataSourceName: dataSourceName,
                                      title: title,
                                      propertyMap: Dictionary(uniqueKeysWithValues:
                                        map.map { ($0.key.rawValue, $0.value) }),
                                      lastValidatedAt: Date(), validationState: "valid")
        context.insert(binding)
        try? context.save()
    }
}
