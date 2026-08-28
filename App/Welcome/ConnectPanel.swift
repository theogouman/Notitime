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
                        .font(.system(size: 34, weight: .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Staggered(index: 1, shown: shown) {
                    Text("On a besoin de se connecter à ton Notion, 2 options :")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
            }

            // `fixedSize` sur la rangée : les cartes s'étirent alors à la
            // hauteur de la plus haute, sans que la rangée n'occupe l'écran.
            HStack(alignment: .top, spacing: 16) {
                Staggered(index: 2, shown: shown) {
                    option(title: "Tu utilises notre template",
                           detail: ConnectPanel.templateSentence,
                           symbol: "square.on.square")
                }
                Staggered(index: 3, shown: shown) {
                    option(title: "Tu utilises tes bases de données déjà existantes",
                           detail: Text("Dans ce cas, tu sélectionneras les pages à connecter pour que Notitime s'y connecte."),
                           symbol: "link")
                }
            }
            .fixedSize(horizontal: false, vertical: true)

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
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { shown = true }
    }

    private func option(title: LocalizedStringKey, detail: Text,
                        symbol: String) -> some View {
        WelcomeCard(stretches: true) {
            VStack(alignment: .leading, spacing: 12) {
                // Illustration à venir : elle remplacera cet emplacement.
                ImagePlaceholder(ratio: 16 / 9, symbol: symbol)
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                detail
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// La commande de Notion est citée telle qu'elle apparaît à l'écran : en
    /// style de code, sur fond contrasté. Les guillemets deviennent inutiles —
    /// c'est le fond qui dit où la citation commence et où elle finit.
    private static var templateSentence: Text {
        var opening = AttributedString(String(localized: "Dans ce cas, tu cliqueras sur "))
        var code = AttributedString("Use a template provided by the developer")
        code.font = .system(size: 13, weight: .medium, design: .monospaced)
        code.foregroundColor = .white
        code.backgroundColor = Color(red: 0.17, green: 0.18, blue: 0.21)
        let closing = AttributedString(String(localized: " pour que notre template soit dupliqué."))
        opening.append(code)
        opening.append(closing)
        return Text(opening)
    }

    /// Ce que fait l'application pendant l'aller-retour dans le navigateur, et
    /// ce qui a échoué le cas échéant : sans cela, l'écran paraît figé.
    @ViewBuilder
    private var status: some View {
        switch model.step {
        case .connecting:
            // Plus court que le bouton qu'il accompagne : une ligne d'attente
            // plus large que l'action qu'elle suit déséquilibre l'écran.
            ShimmerText(text: "On se connecte à Notion…",
                        font: .system(size: 14, weight: .medium))
        case .discovering:
            ShimmerText(text: "Détection des bases…",
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
