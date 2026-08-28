import SwiftUI

/// Deuxième écran : le template offert et ce qu'il contient.
///
/// Les vignettes sont volontairement vides. Les images et les textes viendront ;
/// la grille, elle, tient déjà sa place, sa proportion et son rythme.
struct TemplatePanel: View {

    let start: () -> Void

    @State private var shown = false

    private let columns = [GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14),
                           GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Staggered(index: 0, shown: shown) {
                    Text("On t'offre le template Notion pour bien t'organiser")
                        .font(.system(size: 34, weight: .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Staggered(index: 1, shown: shown) {
                    Text("Le système parfait pour organiser tes projets & tâches, avec un dashboard d'analyse du temps passé")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        // Sans cela la phrase se fait rogner au lieu de passer
                        // à la ligne : SwiftUI la tient pour une ligne unique.
                        .fixedSize(horizontal: false, vertical: true)
                        // Assez étroit pour que la phrase se coupe en deux lignes de
                        // longueur voisine : au-delà, la première en prenait
                        // douze mots et la seconde quatre.
                        .frame(maxWidth: 440)
                }
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(TemplatePanel.features.enumerated()), id: \.offset) { rank, feature in
                    Staggered(index: rank + 2, shown: shown) {
                        WelcomeCard(stretches: true) {
                            VStack(alignment: .leading, spacing: 12) {
                                ImagePlaceholder(symbol: feature.symbol)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feature.title)
                                        .font(.system(size: 17, weight: .medium))
                                    Text(feature.detail)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }

            Staggered(index: TemplatePanel.features.count + 2, shown: shown) {
                PrimaryCTA(title: "Démarrer", action: start)
            }
        }
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { shown = true }
    }

    private struct Feature {
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    /// À remplacer par les vraies captures et les vrais textes.
    private static let features = [
        Feature(symbol: "checklist", title: "Titre à venir", detail: "Description à venir."),
        Feature(symbol: "folder", title: "Titre à venir", detail: "Description à venir."),
        Feature(symbol: "chart.bar.xaxis", title: "Titre à venir", detail: "Description à venir."),
        Feature(symbol: "calendar", title: "Titre à venir", detail: "Description à venir."),
        Feature(symbol: "timer", title: "Titre à venir", detail: "Description à venir."),
        Feature(symbol: "person.2", title: "Titre à venir", detail: "Description à venir.")
    ]
}
