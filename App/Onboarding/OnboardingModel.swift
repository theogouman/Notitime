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
        /// La détection n'a rien remonté du tout. Distinct de `needsAssignment` :
        /// il n'y a rien à proposer, l'écran doit expliquer et offrir un recours
        /// plutôt que de laisser l'utilisateur sans issue (FR-015a).
        case nothingFound
        /// L'utilisateur désigne lui-même ses bases parmi les sources accessibles.
        case manualSelection
        case failed(String)
    }

    @Published private(set) var step: Step = .disconnected
    @Published private(set) var outcome: DiscoveryOutcome?
    @Published private(set) var workspaceName: String = ""
    @Published private(set) var ownerName: String = ""
    /// Propriétés manquantes par rôle, avec ce que l'app sait créer (FR-006).
    @Published private(set) var missingByRole: [DatabaseRole: [PropertyKey]] = [:]
    /// Sources proposées à la désignation manuelle, sans filtre de schéma.
    @Published private(set) var accessibleSources: [AccessibleSource] = []
    /// Ce qui a échoué, en clair, pour l'écran « rien trouvé ».
    @Published private(set) var emptyReason: String = ""
    /// Rôles liés et nom de leur source.
    ///
    /// Publié, et non recalculé à la demande depuis SwiftData : une assignation
    /// qui ne change pas l'étape ne provoquait alors aucun redessin, et l'écran
    /// restait identique alors que la liaison avait bien été enregistrée.
    @Published private(set) var bindings: [DatabaseRole: String] = [:]

    private let environment: AppEnvironment
    private let flow = OAuthFlow()
    /// Conservé pour pouvoir relancer la détection sans refaire tout l'OAuth :
    /// une duplication lente est la première cause d'une détection vide.
    private var templateID: String?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Vrai quand la configuration permet de travailler.
    var isConfigured: Bool {
        !workspaceName.isEmpty || !boundRoles.isEmpty ? requiredRolesAreBound : false
    }

    /// Rétablit ce que la persistance sait déjà, pour ne pas proposer de
    /// reconnecter un workspace déjà relié à chaque lancement.
    func restoreFromPersistence() {
        let context = environment.container.mainContext
        guard let connection = try? context.fetch(FetchDescriptor<NotionConnection>()).first
        else { return }

        workspaceName = connection.workspaceName
        ownerName = connection.ownerName
        templateID = connection.duplicatedTemplateID
        reloadBindings()
        step = requiredRolesAreBound ? .ready : .disconnected
    }

    // MARK: - Connexion

    func connect() async {
        step = .connecting
        do {
            let (callback, verifier) = try await flow.authorize()
            let authorization = try await environment.connection.connect(
                code: callback.code, state: callback.state, verifier: verifier
            )
            // T109 — changer de workspace invalide les entrées en attente, qui
            // référencent des pages de l'ancien. On prévient avant d'écraser.
            if await environment.connection.isDifferentWorkspace(authorization) {
                await environment.log.log(.auth, "workspace différent : "
                                          + "la configuration précédente est remplacée")
                emptyReason = "Vous avez changé de workspace. Les bases liées et les "
                            + "entrées en attente de l'ancien workspace ne sont plus valides."
            }
            workspaceName = authorization.workspaceName ?? ""
            ownerName = authorization.owner?.user?.name ?? ""
            persist(authorization)
            // La page du template reste la meilleure piste même quand cette
            // autorisation-ci ne la mentionne pas : on repart de ce qu'on sait.
            await discover(templateID: authorization.duplicatedTemplateID ?? templateID)
        } catch OAuthFlow.FlowError.userCancelled {
            // US1.4 : une annulation n'est pas une erreur technique. On revient
            // simplement à l'état déconnecté, sans message alarmant.
            step = .disconnected
        } catch {
            step = .failed(describe(error))
        }
    }

    func disconnect() async {
        do {
            try await environment.connection.disconnect()
            step = .disconnected
            outcome = nil
        } catch {
            step = .failed(describe(error))
        }
    }

    // MARK: - Découverte

    private func discover(templateID: String?) async {
        self.templateID = templateID
        step = .discovering
        let discovery = makeDiscovery()
        do {
            let usedTemplate = !(templateID ?? "").isEmpty
            let result: DiscoveryOutcome
            if usedTemplate, let templateID {
                // FR-004 : le template dupliqué se découvre tout seul.
                result = try await discovery.discoverFromTemplate(pageID: templateID)
            } else {
                // FR-005 : sinon, on liste et on pré-sélectionne.
                result = try await discovery.discoverFromAccessibleSources()
            }
            outcome = result
            await persist(result)
            await logOutcome(result)

            guard !result.isEmpty else {
                // Ne jamais afficher un écran d'assignation sans rien à assigner :
                // l'utilisateur n'y comprendrait rien et n'aurait aucun recours.
                emptyReason = usedTemplate
                    ? "Notitime n'a trouvé aucune base dans la page dupliquée. "
                    + "La copie effectuée par Notion est peut-être encore en cours, "
                    + "ou les bases ont été déplacées hors de cette page."
                    : "Notitime n'a trouvé aucune base parmi les pages partagées avec "
                    + "l'intégration. Il faut lui donner accès à vos bases dans Notion, "
                    + "ou les désigner vous-même."
                step = .nothingFound
                return
            }

            let complete = result.assigned[.tasks] != nil
                && result.assigned[.timeEntries] != nil
                && result.sourceChoices.isEmpty
            step = complete ? .ready : .needsAssignment
        } catch {
            step = .failed(describe(error))
        }
    }

    /// Trace le détail de la découverte, rôle par rôle.
    ///
    /// C'est ce qui manquait pour comprendre un écran d'assignation inattendu :
    /// savoir ce qui a été assigné, ce qui est resté ambigu, et avec combien de
    /// candidats — sans quoi on ne peut que supposer.
    private func logOutcome(_ result: DiscoveryOutcome) async {
        let assigned = result.assigned
            .map { "\($0.key.rawValue)=\($0.value.dataSourceID)" }
            .sorted().joined(separator: " ")
        let unresolved = result.unresolved
            .map { "\($0.key.rawValue)×\($0.value.count)" }
            .sorted().joined(separator: " ")
        await environment.log.log(.sync, "découverte assignés[\(assigned)] "
                                  + "ambigus[\(unresolved)] choixDeSource=\(result.sourceChoices.count)")
    }

    private func makeDiscovery() -> RoleDiscovery {
        RoleDiscovery(client: environment.notion, time: environment.time, log: environment.log)
    }

    /// FR-006a, T105 — revalide chaque rôle lié et re-résout une source
    /// disparue : une seule candidate est proposée, plusieurs demandent un
    /// choix, aucune rend la configuration invalide.
    func revalidate() async {
        step = .discovering
        let context = environment.container.mainContext
        let stored = (try? context.fetch(FetchDescriptor<DatabaseBinding>())) ?? []
        var broken: [DatabaseRole] = []

        for binding in stored {
            guard let role = DatabaseRole(rawValue: binding.roleRaw) else { continue }
            do {
                let source = try await environment.notion.retrieveDataSource(id: binding.dataSourceID)
                let validation = SchemaValidator().validate(source, as: role,
                                                            existingMap: binding.propertyRefs)
                if case .missing(let missing, _, _) = validation {
                    missingByRole[role] = missing
                    broken.append(role)
                } else {
                    // La revalidation est aussi ce qui rattrape une liaison
                    // enregistrée avant que le modèle de page ne soit constaté.
                    binding.usesDefaultTemplate = await detectsDefaultTemplate(
                        for: role, dataSourceID: binding.dataSourceID)
                    try? context.save()
                }
            } catch {
                // Source disparue : le rôle redevient à désigner.
                await environment.log.log(.sync, "source disparue rôle=\(role.rawValue)")
                broken.append(role)
            }
        }

        reloadBindings()
        if broken.isEmpty {
            step = .ready
            emptyReason = ""
        } else {
            await browseAccessibleSources()
            notice(for: broken)
        }
    }

    private func notice(for broken: [DatabaseRole]) {
        emptyReason = "À revalider : " + broken.map(\.rawValue).joined(separator: ", ")
    }

    /// Relance la détection sans refaire l'OAuth (recours 1 de l'écran vide).
    func retryDiscovery() async {
        await discover(templateID: templateID)
    }

    /// Bascule vers la désignation manuelle (recours 2 de l'écran vide).
    func browseAccessibleSources() async {
        step = .discovering
        do {
            accessibleSources = try await makeDiscovery().allAccessibleSources()
            step = .manualSelection
        } catch {
            step = .failed(describe(error))
        }
    }

    /// Assignation manuelle d'une source à un rôle (FR-005, FR-006a).
    func assign(dataSourceID: String, databaseID: String?, name: String, to role: DatabaseRole) async {
        await environment.log.log(.sync, "assignation demandée rôle=\(role.rawValue) source=\(dataSourceID)")
        do {
            let source = try await environment.notion.retrieveDataSource(id: dataSourceID)
            let validation = SchemaValidator().validate(source, as: role)
            switch validation {
            case .valid(let map):
                missingByRole[role] = nil
                let template = await detectsDefaultTemplate(for: role, dataSourceID: dataSourceID)
                save(role: role, source: source, name: name,
                     databaseID: databaseID ?? source.databaseID, map: map,
                     usesDefaultTemplate: template)
                await environment.log.log(.sync, "assignation réussie rôle=\(role.rawValue) "
                                          + "propriétés=\(map.count) liés=\(boundRoles.count)")
                // Un rôle lié ne signifie pas la configuration terminée : lier
                // Tâches puis basculer en « connecté » laisserait Time Entries
                // sans source, et la première session n'aurait nulle part où aller.
                step = requiredRolesAreBound ? .ready : stepForPendingAssignment()
            case .missing(let missing, _, _):
                // FR-006 : la configuration est refusée tant que le schéma n'est
                // pas valide ; on affiche ce qui manque et on propose de créer.
                missingByRole[role] = missing
                await environment.log.log(.sync, "assignation refusée rôle=\(role.rawValue) "
                                          + "manquantes=[\(missing.map(\.rawValue).joined(separator: " "))]")
                step = stepForPendingAssignment()
            }
        } catch {
            await environment.log.log(.error, "assignation en échec rôle=\(role.rawValue) : \(error)")
            step = .failed(describe(error))
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
            step = .failed(describe(error))
        }
    }

    /// Message d'erreur complet : la suggestion de récupération porte souvent
    /// l'essentiel — c'est elle qui dit à l'utilisateur quoi faire du refus de
    /// trousseau qu'il vient d'opposer à macOS.
    private func describe(_ error: Error) -> String {
        let description = error.localizedDescription
        guard let recovery = (error as? LocalizedError)?.recoverySuggestion else {
            return description
        }
        return description + "\n\n" + recovery
    }

    // MARK: - Rôles liés

    /// Rôles effectivement liés à une source.
    var boundRoles: Set<DatabaseRole> { Set(bindings.keys) }

    /// Relit les liaisons persistées et republie l'état.
    private func reloadBindings() {
        let stored = (try? environment.container.mainContext
            .fetch(FetchDescriptor<DatabaseBinding>())) ?? []
        bindings = Dictionary(
            stored.compactMap { binding in
                DatabaseRole(rawValue: binding.roleRaw).map { ($0, binding.dataSourceName) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Tâches et Time Entries suffisent à démarrer une session ; Projets est
    /// facultatif — une entrée sans projet reste valide (data-model §2).
    private var requiredRolesAreBound: Bool {
        boundRoles.contains(.tasks) && boundRoles.contains(.timeEntries)
    }

    /// Reste sur l'écran d'où vient l'utilisateur plutôt que de le renvoyer
    /// ailleurs au milieu d'une désignation.
    private func stepForPendingAssignment() -> Step {
        step == .manualSelection ? .manualSelection : .needsAssignment
    }

    // MARK: - Persistance

    private func persist(_ authorization: NotionAuthorization) {
        let context = environment.container.mainContext

        // Notion ne renvoie `duplicated_template_id` **qu'à la duplication
        // effective**. Aux autorisations suivantes il est absent, et l'écraser
        // reviendrait à oublier définitivement la page du template : la
        // découverte retomberait à jamais sur la recherche générale, moins sûre.
        let knownTemplateID = try? context.fetch(FetchDescriptor<NotionConnection>())
            .first?.duplicatedTemplateID

        try? context.delete(model: NotionConnection.self)
        context.insert(NotionConnection(
            workspaceID: authorization.workspaceID,
            workspaceName: authorization.workspaceName ?? "",
            workspaceIconURL: authorization.workspaceIcon.flatMap(URL.init(string:)),
            workspaceIconRaw: authorization.workspaceIcon,
            botID: authorization.botID,
            ownerUserID: authorization.owner?.user?.id ?? "",
            ownerName: authorization.owner?.user?.name ?? "",
            duplicatedTemplateID: authorization.duplicatedTemplateID
                ?? knownTemplateID.flatMap { $0 },
            connectedAt: Date()
        ))
        try? context.save()
    }

    private func persist(_ result: DiscoveryOutcome) async {
        defer { reloadBindings() }
        for (role, candidate) in result.assigned {
            let template = await detectsDefaultTemplate(for: role,
                                                        dataSourceID: candidate.dataSourceID)
            save(role: role,
                 dataSourceID: candidate.dataSourceID,
                 dataSourceName: candidate.dataSourceName,
                 databaseID: candidate.databaseID ?? "",
                 title: candidate.databaseTitle,
                 map: candidate.validation.propertyMap,
                 usesDefaultTemplate: template)
        }
    }

    private func save(role: DatabaseRole, source: NotionDataSource, name: String,
                      databaseID: String?, map: [PropertyKey: PropertyRef],
                      usesDefaultTemplate: Bool = false) {
        save(role: role, dataSourceID: source.id,
             dataSourceName: name.isEmpty ? source.title : name,
             databaseID: databaseID ?? "", title: source.title, map: map,
             usesDefaultTemplate: usesDefaultTemplate)
    }

    /// Les entrées de temps naissent du modèle de page de la base, s'il en existe
    /// un par défaut. On le constate une fois, à la liaison : c'est une propriété
    /// de la base, et l'interroger à chaque envoi coûterait le quota pour rien.
    ///
    /// Un échec n'empêche pas de lier : sans modèle, les pages seront simplement
    /// nues, ce qui reste préférable à une configuration bloquée.
    private func detectsDefaultTemplate(for role: DatabaseRole, dataSourceID: String) async -> Bool {
        guard role == .timeEntries else { return false }
        do {
            let has = try await environment.notion.hasDefaultTemplate(dataSourceID: dataSourceID)
            await environment.log.log(.sync, "modèle de page par défaut=\(has ? "oui" : "non") "
                                      + "source=\(dataSourceID)")
            return has
        } catch {
            await environment.log.log(.sync, "modèles de page illisibles : \(error) — "
                                      + "les entrées seront créées sans modèle")
            return false
        }
    }

    private func save(role: DatabaseRole, dataSourceID: String, dataSourceName: String,
                      databaseID: String, title: String, map: [PropertyKey: PropertyRef],
                      usesDefaultTemplate: Bool = false) {
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
                                      lastValidatedAt: Date(), validationState: "valid",
                                      usesDefaultTemplate: usesDefaultTemplate)
        context.insert(binding)
        try? context.save()
        reloadBindings()
    }
}
