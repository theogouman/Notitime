import SwiftUI
import NotitimeCore

/// Troisième écran : ce qui va se passer dans le navigateur.
///
/// Les deux cas ne se ressemblent pas — dupliquer un template, ou partager des
/// bases existantes — et l'écran d'autorisation de Notion ne le dit pas. Les
/// annoncer ici évite de découvrir le choix au milieu du flux.
struct ConnectPanel: View {

    @ObservedObject var model: OnboardingModel

    @State private var shown = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Staggered(index: 0, shown: shown) {
                    Text("Avant de te donner accès à Notitime…")
                        .font(.system(size: 28, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
                Staggered(index: 1, shown: shown) {
                    Text("On a besoin de se connecter à ton Notion, 2 options :")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Staggered(index: 2, shown: shown) {
                    option(title: "Tu utilises notre template",
                           detail: "Dans ce cas, tu cliqueras sur « Use a template provided by the developer » pour que notre template soit dupliqué.",
                           symbol: "square.on.square")
                }
                Staggered(index: 3, shown: shown) {
                    option(title: "Tu utilises tes bases de données déjà existantes",
                           detail: "Dans ce cas, tu devras donner l'accès à Notitime.",
                           symbol: "link")
                }
            }

            Staggered(index: 4, shown: shown) {
                VStack(spacing: 10) {
                    PrimaryCTA(title: "Connecter mon Notion",
                               showsNotionLogo: true, showsArrow: false) {
                        Task { await model.connect() }
                    }
                    status
                }
            }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { shown = true }
    }

    private func option(title: LocalizedStringKey, detail: LocalizedStringKey,
                        symbol: String) -> some View {
        WelcomeCard {
            VStack(alignment: .leading, spacing: 12) {
                // Illustration à venir : elle remplacera cet emplacement.
                ImagePlaceholder(ratio: 16 / 9, symbol: symbol)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Ce que fait l'application pendant l'aller-retour dans le navigateur, et
    /// ce qui a échoué le cas échéant : sans cela, l'écran paraît figé.
    @ViewBuilder
    private var status: some View {
        switch model.step {
        case .connecting:
            ShimmerText(text: "Autorisation en cours dans votre navigateur…",
                        font: .system(size: 14, weight: .medium))
        case .discovering:
            ShimmerText(text: "Détection des bases Notion…",
                        font: .system(size: 14, weight: .medium))
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        default:
            Color.clear.frame(height: 18)
        }
    }
}
