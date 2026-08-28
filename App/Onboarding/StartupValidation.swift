import Foundation
import SwiftData
import NotitimeCore

/// Revalidation des rôles au démarrage (T043, cas limite « template modifié »).
///
/// Sans elle, un renommage de propriété côté Notion ne se manifesterait qu'au
/// moment d'envoyer une entrée — c'est-à-dire trop tard, une session étant déjà
/// terminée. La spec veut que l'échec soit détecté au démarrage et que
/// l'utilisateur soit invité à re-mapper.
@MainActor
struct StartupValidation {

    enum Result: Equatable {
        case valid
        case notConfigured
        /// Le schéma ne correspond plus : router vers l'écran de re-mapping.
        case needsRemapping(role: DatabaseRole, missing: [PropertyKey])
        /// La source mémorisée n'existe plus ; plusieurs candidates subsistent (FR-006a).
        case needsSourceChoice(role: DatabaseRole, sources: [NotionDataSourceRef])
        case unreachable(String)
    }

    let environment: AppEnvironment

    func run() async -> Result {
        let context = environment.container.mainContext
        guard let bindings = try? context.fetch(FetchDescriptor<DatabaseBinding>()),
              !bindings.isEmpty else {
            return .notConfigured
        }

        let validator = SchemaValidator()
        for binding in bindings {
            guard let role = binding.role else { continue }
            do {
                let source = try await environment.notion.retrieveDataSource(id: binding.dataSourceID)
                let pinned = Dictionary(uniqueKeysWithValues: binding.propertyMap.compactMap {
                    key, value in PropertyKey(rawValue: key).map { ($0, value) }
                })
                switch validator.validate(source, as: role, existingMap: pinned) {
                case .valid(let map):
                    binding.propertyMap = Dictionary(uniqueKeysWithValues:
                        map.map { ($0.key.rawValue, $0.value) })
                    binding.lastValidatedAt = Date()
                    binding.validationStateRaw = "valid"
                    await refreshDefaultTemplate(binding, role: role)
                case .missing(let missing, _, _):
                    binding.validationStateRaw = "missingProperties"
                    try? context.save()
                    return .needsRemapping(role: role, missing: missing)
                }
            } catch let error as NotionError where error.responseClass == .permanent(.notFound) {
                // La source a disparu : on re-résout les sources de la base.
                if let choice = await resolveReplacement(for: binding, role: role) {
                    return choice
                }
                binding.validationStateRaw = "invalid"
                try? context.save()
                return .needsRemapping(role: role, missing: [])
            } catch {
                // Notion injoignable : ce n'est pas une invalidation. Le cache
                // reste utilisable, on ne casse pas la configuration.
                return .unreachable(error.localizedDescription)
            }
        }
        try? context.save()
        return .valid
    }

    /// Le modèle de page par défaut est reconstaté à chaque lancement.
    ///
    /// C'est une propriété de la base, pas de la liaison : elle peut recevoir un
    /// modèle par défaut longtemps après avoir été liée, et une liaison plus
    /// ancienne que la détection gardait « non » indéfiniment — les entrées
    /// naissaient nues sans que rien ne le dise. Une lecture impossible laisse
    /// le drapeau tel quel : Notion injoignable n'est pas un modèle disparu.
    private func refreshDefaultTemplate(_ binding: DatabaseBinding,
                                        role: DatabaseRole) async {
        guard role == .timeEntries else { return }
        var outcome = DefaultTemplateProbe.Outcome.unreadable
        do {
            outcome = .has(try await environment.notion
                .hasDefaultTemplate(dataSourceID: binding.dataSourceID))
        } catch {
            await environment.log.log(.sync, "modèles de page illisibles : \(error)")
        }
        let decided = DefaultTemplateProbe.decide(role: role,
                                                  current: binding.usesDefaultTemplate,
                                                  outcome: outcome)
        if decided != binding.usesDefaultTemplate {
            await environment.log.log(.sync, "modèle de page par défaut \(decided ? "adopté" : "abandonné") "
                                      + "source=\(binding.dataSourceID)")
        }
        binding.usesDefaultTemplate = decided
    }

    /// S'il ne reste qu'une source, on la propose ; s'il y en a plusieurs, on
    /// redemande le choix ; s'il n'y en a aucune, la configuration est invalide.
    private func resolveReplacement(for binding: DatabaseBinding,
                                    role: DatabaseRole) async -> Result? {
        guard !binding.databaseID.isEmpty,
              let database = try? await environment.notion.retrieveDatabase(id: binding.databaseID)
        else { return nil }

        switch database.dataSources.count {
        case 0:
            return nil
        case 1:
            binding.dataSourceID = database.dataSources[0].id
            binding.dataSourceName = database.dataSources[0].name
            return nil
        default:
            return .needsSourceChoice(role: role, sources: database.dataSources)
        }
    }
}
