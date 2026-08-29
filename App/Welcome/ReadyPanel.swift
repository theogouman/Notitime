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
///
/// La pastille est dessinée dans un `Button`, et le menu ouvert par
/// `NativeMenuAnchor` : en libellé de `Menu`, AppKit n'en garderait que le
/// texte et l'image, et le fond noir disparaîtrait sur macOS 15.
struct DatabaseChip: View {

    @ObservedObject var model: OnboardingModel
    let role: DatabaseRole

    @State private var hovered = false
    @State private var opensMenu = false

    var body: some View {
        Button { opensMenu = true } label: {
            HStack(spacing: 8) {
                Image("DatabaseIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(.white.opacity(0.75))
                Text(model.bindings[role] ?? "à désigner")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(model.bindings[role] == nil ? Color.orange : Color.white)
                // La double flèche dit que le nom se change : sans elle, rien ne
                // distingue une base liée d'un mot de la phrase.
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            // Fond noir, quel que soit le thème : le nom d'une base est une
            // valeur, pas une phrase, et il doit se voir comme telle.
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(hovered ? 0.78 : 0.92))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            NativeMenuAnchor(header: String(localized: "Quelle base de données ?"),
                             entries: entries,
                             emptyTitle: String(localized: "Aucune base partagée avec Notitime"),
                             isPresented: $opensMenu)
        )
        .fixedSize()
        .onHover { hovered = $0 }
        .help("Changer de base")
        .accessibilityLabel("Changer de base")
    }

    private var entries: [NativeMenuEntry] {
        model.accessibleSources.map { source in
            NativeMenuEntry(id: source.id,
                            title: source.name.isEmpty
                                ? String(localized: "Sans titre") : source.name) {
                Task {
                    await model.assign(dataSourceID: source.id,
                                       databaseID: source.databaseID,
                                       name: source.name, to: role,
                                       changesStep: false)
                }
            }
        }
    }
}
