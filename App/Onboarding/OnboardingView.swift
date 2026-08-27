import SwiftUI
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
            case .failed(let message):
                failure(message)
            }
        }
    }

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connecter mon Notion")
                .font(.headline)
            Text("Dupliquez le template proposé, ou choisissez des pages existantes : "
                 + "Notitime reconnaîtra vos bases.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connecter mon Notion") {
                Task { await model.connect() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).font(.callout)
        }
    }

    @ViewBuilder
    private var assignment: some View {
        Text("Désigner vos bases").font(.headline)

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
