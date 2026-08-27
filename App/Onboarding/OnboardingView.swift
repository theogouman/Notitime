import SwiftUI
import AppKit
import NotitimeCore

/// Écran de connexion et d'assignation des rôles (US1.1 à US1.3, FR-005, FR-006a).
struct OnboardingView: View {

    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.step {
            case .disconnected:
                disconnected
            case .connecting:
                progress("Autorisation en cours dans votre navigateur…")
            case .discovering:
                progress("Détection des bases Notion…")
            case .ready:
                ConnectionStatusView(model: model)
            case .needsAssignment:
                assignment
            case .nothingFound:
                nothingFound
            case .manualSelection:
                manualSelection
            case .failed(let message):
                failure(message)
            }
        }
    }

    /// Premier écran : ce que fait l'application, et une seule chose à faire.
    ///
    /// Le logo vient du bundle plutôt que d'un asset dédié : il reste ainsi
    /// exactement celui du Dock et du Finder, sans copie à maintenir.
    private var disconnected: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Notitime")
                    .font(.largeTitle.weight(.semibold))
                Text("Mesurez combien de temps vous passez sur vos tâches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await model.connect() }
            } label: {
                HStack(spacing: 8) {
                    Text("Connecter mon Notion")
                    // Gabarit : le logo prend la couleur du libellé, donc blanc
                    // sur le bouton teinté, et lisible dans les deux thèmes.
                    Image("NotionLogo")
                        .renderingMode(.template)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Dupliquez le template proposé, ou choisissez des pages existantes : "
                 + "Notitime reconnaîtra vos bases.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).font(.callout)
        }
    }

    /// État de chaque rôle, toujours visible pendant la configuration.
    ///
    /// Sans lui, assigner un rôle qui ne suffit pas à terminer la configuration
    /// ne produisait aucun changement à l'écran : la liaison était pourtant
    /// enregistrée, mais rien ne le disait.
    @ViewBuilder
    private var roleStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([DatabaseRole.tasks, .timeEntries, .projects], id: \.self) { role in
                HStack(spacing: 6) {
                    Image(systemName: model.bindings[role] != nil
                          ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(model.bindings[role] != nil ? .green : .secondary)
                    Text(roleLabel(role)).font(.caption)
                    if let source = model.bindings[role] {
                        Text("— \(source)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var assignment: some View {
        Text("Désigner vos bases").font(.headline)
        roleStatus

        if let outcome = model.outcome {
            // FR-006a : une base à plusieurs sources se tranche explicitement.
            ForEach(outcome.sourceChoices, id: \.databaseID) { choice in
                VStack(alignment: .leading, spacing: 4) {
                    Text("« \(choice.databaseTitle) » contient plusieurs sources de données.")
                        .font(.callout)
                    Text("Choisissez celle qui porte vos données.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(choice.sources, id: \.id) { source in
                        Button(source.name) {
                            Task {
                                await model.assign(dataSourceID: source.id,
                                                   databaseID: choice.databaseID,
                                                   name: source.name,
                                                   to: .timeEntries)
                            }
                        }
                    }
                }
            }

            ForEach(Array(outcome.unresolved.keys), id: \.self) { role in
                VStack(alignment: .leading, spacing: 4) {
                    Text(roleLabel(role)).font(.callout).bold()
                    ForEach(outcome.unresolved[role] ?? [], id: \.dataSourceID) { candidate in
                        Button(candidate.dataSourceName) {
                            Task {
                                await model.assign(dataSourceID: candidate.dataSourceID,
                                                   databaseID: candidate.databaseID,
                                                   name: candidate.dataSourceName,
                                                   to: role)
                            }
                        }
                    }
                }
            }
        }

        // FR-006 : propriétés manquantes listées, création proposée.
        ForEach(Array(model.missingByRole.keys), id: \.self) { role in
            if let missing = model.missingByRole[role], !missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Propriétés manquantes dans \(roleLabel(role))")
                        .font(.callout).bold()
                    Text(missing.map(\.rawValue).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// FR-015a : un état vide s'explique et propose une action. Sans cela
    /// l'utilisateur n'a plus qu'à quitter, sans savoir ce qui a échoué.
    @ViewBuilder
    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aucune base détectée").font(.headline)
            Text(model.emptyReason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Réessayer la détection") {
                    Task { await model.retryDiscovery() }
                }
                .buttonStyle(.borderedProminent)

                Button("Choisir mes bases moi-même") {
                    Task { await model.browseAccessibleSources() }
                }
            }

            Text("Si la duplication vient d'avoir lieu, laissez à Notion quelques "
                 + "secondes puis réessayez.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Désignation manuelle : toutes les sources accessibles, rôle par rôle.
    @ViewBuilder
    private var manualSelection: some View {
        Text("Choisir mes bases").font(.headline)
        roleStatus

        if model.accessibleSources.isEmpty {
            // Deuxième impasse possible : ne pas la laisser muette non plus.
            Text("Aucune source de données n'est partagée avec Notitime. Ouvrez la "
                 + "page de vos bases dans Notion, puis « Connexions » → Notitime.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Réessayer") { Task { await model.browseAccessibleSources() } }
        } else {
            ForEach(rolesToBind, id: \.self) { role in
                VStack(alignment: .leading, spacing: 4) {
                    Text(roleLabel(role)).font(.callout).bold()
                    ForEach(model.accessibleSources) { source in
                        Button(source.name.isEmpty ? "Sans titre" : source.name) {
                            Task {
                                await model.assign(dataSourceID: source.id,
                                                   databaseID: source.databaseID,
                                                   name: source.name,
                                                   to: role)
                            }
                        }
                    }
                    if let missing = model.missingByRole[role], !missing.isEmpty {
                        Text("Propriétés manquantes : "
                             + missing.map(\.rawValue).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Rôles restant à lier, dans l'ordre où ils comptent pour démarrer.
    private var rolesToBind: [DatabaseRole] {
        [.tasks, .timeEntries, .projects].filter { !model.boundRoles.contains($0) }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connexion impossible").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Réessayer") { Task { await model.connect() } }
        }
    }

    private func roleLabel(_ role: DatabaseRole) -> String {
        switch role {
        case .tasks: return "Tâches"
        case .timeEntries: return "Time Entries"
        case .projects: return "Projets"
        }
    }
}
