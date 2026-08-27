import SwiftUI
import SwiftData
import NotitimeCore

/// État de la connexion : workspace en titre, bases liées en tableau, et
/// déconnexion avec avertissement si des entrées attendent (FR-007, FR-008).
struct ConnectionStatusView: View {

    @ObservedObject var model: OnboardingModel
    @Query private var connections: [NotionConnection]
    @Query private var bindings: [DatabaseBinding]
    @Query private var pending: [OutboxEntry]

    @State private var confirmingDisconnect = false
    /// Rôle dont l'utilisateur veut changer la base, `nil` quand la feuille est
    /// fermée. Porte l'identité de la feuille : la présenter par un booléen
    /// séparé laisserait une fenêtre où le rôle n'est pas encore connu.
    @State private var rebinding: DatabaseRole?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let connection = connections.first {
                header(connection)
                databases
                Divider()
                disconnect
            }
        }
        .sheet(item: $rebinding) { role in
            DatabasePickerSheet(model: model, role: role) { rebinding = nil }
        }
    }

    // MARK: - En-tête

    @ViewBuilder
    private func header(_ connection: NotionConnection) -> some View {
        HStack(alignment: .center, spacing: 10) {
            WorkspaceIconView(icon: connection.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.workspaceName.isEmpty ? "Workspace Notion" : connection.workspaceName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(ConnectionStatusView.connectedLabel(connection.connectedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// « Connecté le 27 août 2026 à 16:20 » — la date compte : une liaison
    /// vieille de plusieurs mois explique bien des surprises de schéma.
    static func connectedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return "Connecté le \(formatter.string(from: date))"
    }

    // MARK: - Bases liées (FR-007)

    private var rows: [DatabaseRow] {
        DatabaseRole.allCases.map { role in
            let binding = bindings.first { $0.roleRaw == role.rawValue }
            return DatabaseRow(
                role: role,
                source: binding.map { $0.dataSourceName.isEmpty ? $0.title : $0.dataSourceName },
                isOptional: role == .projects
            )
        }
    }

    @ViewBuilder
    private var databases: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bases liées").font(.headline)
            Table(rows) {
                TableColumn("Rôle") { row in
                    Text(row.label)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Base de données") { row in
                    if let source = row.source {
                        Text(source).lineLimit(1)
                    } else {
                        Text(row.isOptional ? "optionnelle" : "à désigner")
                            .foregroundStyle(row.isOptional ? Color.secondary : Color.orange)
                    }
                }

                TableColumn("") { row in
                    // FR-007 : changer de base à tout moment, la revalidation
                    // ayant lieu avant que le changement ne soit accepté.
                    Button(row.source == nil ? "Désigner…" : "Modifier…") {
                        rebinding = row.role
                    }
                    .buttonStyle(.link)
                }
                .width(80)
            }
            .frame(minHeight: 108, maxHeight: 132)
            Text("Chaque changement revalide le schéma de la base avant d'être accepté.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Déconnexion

    @ViewBuilder
    private var disconnect: some View {
        Button("Se déconnecter") { confirmingDisconnect = true }
            .confirmationDialog(disconnectPrompt, isPresented: $confirmingDisconnect) {
                Button("Se déconnecter", role: .destructive) {
                    Task { await model.disconnect() }
                }
                Button("Annuler", role: .cancel) {}
            }
    }

    /// FR-008 : avertir si des entrées sont encore en attente d'envoi.
    private var disconnectPrompt: String {
        pending.isEmpty
            ? "Se déconnecter de Notion ?"
            : "\(pending.count) entrée(s) attendent d'être envoyées. Elles resteront en file "
            + "et repartiront à la prochaine connexion. Se déconnecter ?"
    }
}

/// Une ligne du tableau des bases.
struct DatabaseRow: Identifiable {
    let role: DatabaseRole
    let source: String?
    let isOptional: Bool

    var id: String { role.rawValue }

    var label: String {
        switch role {
        case .tasks: return "Tâches"
        case .timeEntries: return "Time Entries"
        case .projects: return "Projets"
        }
    }
}

/// Icône du workspace : image distante ou emoji, selon ce que Notion renvoie.
struct WorkspaceIconView: View {
    let icon: WorkspaceIcon
    var side: CGFloat = 34

    var body: some View {
        Group {
            switch icon {
            case .image(let url):
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            case .emoji(let emoji):
                Text(emoji).font(.system(size: side * 0.62))
            case .none:
                placeholder
            }
        }
        .frame(width: side, height: side)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "square.grid.2x2")
            .foregroundStyle(.secondary)
    }
}

/// Choix d'une autre source pour un rôle donné (FR-007).
struct DatabasePickerSheet: View {

    @ObservedObject var model: OnboardingModel
    let role: DatabaseRole
    let onClose: () -> Void

    @State private var isLoading = true
    @State private var search = ""

    private var sources: [AccessibleSource] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.accessibleSources }
        return model.accessibleSources.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choisir la base « \(DatabaseRow(role: role, source: nil, isOptional: false).label) »")
                .font(.headline)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lecture des bases partagées avec Notitime…").font(.callout)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if model.accessibleSources.isEmpty {
                Text("Aucune base n'est partagée avec Notitime. Ouvrez la base dans "
                     + "Notion, puis « Connexions » → Notitime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                TextField("Rechercher une base", text: $search)
                    .textFieldStyle(.roundedBorder)
                List(sources) { source in
                    HStack {
                        Text(source.name.isEmpty ? "Sans titre" : source.name)
                        Spacer()
                        Button("Lier") {
                            Task {
                                await model.assign(dataSourceID: source.id,
                                                   databaseID: source.databaseID,
                                                   name: source.name, to: role)
                                onClose()
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }

            // FR-006 : un schéma incomplet se dit, et n'est pas accepté.
            if let missing = model.missingByRole[role], !missing.isEmpty {
                Text("Propriétés manquantes : " + missing.map(\.rawValue).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Fermer") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .task {
            await model.browseAccessibleSources()
            isLoading = false
        }
    }
}
