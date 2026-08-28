import SwiftUI
import NotitimeCore

/// Quatrième écran : ce que Notitime a compris de ton espace.
///
/// Deux phrases plutôt qu'un tableau : la configuration se relit alors comme
/// une phrase, et chaque base y est un mot qu'on peut changer sur place.
struct ReadyPanel: View {

    @ObservedObject var model: OnboardingModel
    let finish: () -> Void

    @State private var shown = false

    var body: some View {
        VStack(spacing: 26) {
            Staggered(index: 0, shown: shown) {
                Text("Parfait, Notion est bien connecté !")
                    .font(.system(size: 28, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 16) {
                Staggered(index: 1, shown: shown) {
                    HStack(spacing: 7) {
                        Text("On récupère tes tâches dans")
                        DatabaseChip(model: model, role: .tasks)
                        Text("qui sont liés à tes")
                        DatabaseChip(model: model, role: .projects)
                    }
                    .font(.system(size: 17))
                }
                Staggered(index: 2, shown: shown) {
                    HStack(spacing: 7) {
                        Text("…Et on enverra ton Time Tracking dans")
                        DatabaseChip(model: model, role: .timeEntries)
                    }
                    .font(.system(size: 17))
                }
            }

            Staggered(index: 3, shown: shown) {
                VStack(spacing: 10) {
                    PrimaryCTA(title: "Lancer mon premier Time Tracking", action: finish)
                        .disabled(!model.isConfigured)
                        .opacity(model.isConfigured ? 1 : 0.5)
                    if !model.isConfigured {
                        Text("Désignez au moins vos bases Tâches et Time Entries pour continuer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { shown = true }
        // Les sources partagées alimentent les menus de changement : on les lit
        // une fois en arrivant, pas à chaque ouverture de menu.
        .task { try? await model.fetchAccessibleSources() }
    }
}

/// Le nom d'une base, sur fond contrasté, précédé de l'icône de base Notion.
/// Un clic ouvre la liste des bases partagées pour en changer.
struct DatabaseChip: View {

    @ObservedObject var model: OnboardingModel
    let role: DatabaseRole

    @State private var hovered = false

    var body: some View {
        Menu {
            if model.accessibleSources.isEmpty {
                Text("Aucune base partagée avec Notitime")
            }
            ForEach(model.accessibleSources) { source in
                Button(source.name.isEmpty ? "Sans titre" : source.name) {
                    Task {
                        await model.assign(dataSourceID: source.id,
                                           databaseID: source.databaseID,
                                           name: source.name, to: role,
                                           changesStep: false)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image("DatabaseIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.secondary)
                Text(model.bindings[role] ?? "à désigner")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.bindings[role] == nil ? Color.orange : Color.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.14 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Changer de base")
    }
}
