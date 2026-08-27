import SwiftUI
import SwiftData
import NotitimeCore

/// État de la connexion : nom d'utilisateur, workspace, rôles liés, et
/// déconnexion avec avertissement si des entrées attendent (FR-008, US1.1).
struct ConnectionStatusView: View {

    @ObservedObject var model: OnboardingModel
    @Query private var connections: [NotionConnection]
    @Query private var bindings: [DatabaseBinding]
    @Query private var pending: [OutboxEntry]

    @State private var confirmingDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let connection = connections.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.ownerName.isEmpty ? "Connecté" : connection.ownerName)
                        .font(.headline)
                    Text(connection.workspaceName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                ForEach(DatabaseRole.allCases, id: \.self) { role in
                    HStack {
                        Text(label(for: role))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let binding = bindings.first(where: { $0.roleRaw == role.rawValue }) {
                            Text(binding.dataSourceName.isEmpty ? binding.title : binding.dataSourceName)
                        } else {
                            Text(role == .projects ? "optionnel" : "à assigner")
                                .foregroundStyle(role == .projects ? Color.secondary : Color.orange)
                        }
                    }
                    .font(.callout)
                }

                Divider()

                Button("Se déconnecter") { confirmingDisconnect = true }
                    .confirmationDialog(disconnectPrompt, isPresented: $confirmingDisconnect) {
                        Button("Se déconnecter", role: .destructive) {
                            Task { await model.disconnect() }
                        }
                        Button("Annuler", role: .cancel) {}
                    }
            }
        }
    }

    /// FR-008 : avertir si des entrées sont encore en attente d'envoi.
    private var disconnectPrompt: String {
        pending.isEmpty
            ? "Se déconnecter de Notion ?"
            : "\(pending.count) entrée(s) attendent d'être envoyées. Elles resteront en file "
            + "et repartiront à la prochaine connexion. Se déconnecter ?"
    }

    private func label(for role: DatabaseRole) -> String {
        switch role {
        case .tasks: return "Tâches"
        case .timeEntries: return "Time Entries"
        case .projects: return "Projets"
        }
    }
}
