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
                    .font(.system(size: 34, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 16) {
                Staggered(index: 1, shown: shown) {
                    HStack(spacing: 7) {
                        Text("On récupère tes tâches dans")
                        DatabaseChip(model: model, role: .tasks)
                        Text("qui sont liés à tes")
                        DatabaseChip(model: model, role: .projects)
                    }
                    .font(.system(size: 22))
                }
                Staggered(index: 2, shown: shown) {
                    HStack(spacing: 7) {
                        Text("…Et on enverra ton Time Tracking dans")
                        DatabaseChip(model: model, role: .timeEntries)
                    }
                    .font(.system(size: 22))
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
            // Un titre au-dessus de la liste : ouvert au milieu d'une phrase,
            // le menu doit dire de quoi il parle.
            Section("Quelle base de données ?") {
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
            }
        } label: {
            HStack(spacing: 7) {
                Image("DatabaseIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(Color.accentColor)
                Text(model.bindings[role] ?? "à désigner")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(model.bindings[role] == nil ? Color.orange : Color.primary)
                // La double flèche dit que le nom se change : sans elle, rien ne
                // distingue une base liée d'un mot de la phrase.
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(hovered ? 0.28 : 0.16)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Changer de base")
    }
}
