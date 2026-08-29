import SwiftUI
import AppKit

/// Invitation à connecter Notion : logo, nom, ce que fait l'application, et un
/// seul bouton.
///
/// Partagée par la fenêtre d'accueil et par le menu de la barre de menus. Les
/// deux montraient jusqu'ici des choses différentes de la même situation — le
/// menu proposait de démarrer une session pendant que la fenêtre proposait de se
/// connecter. Une seule vue, deux tailles.
struct ConnectPromptView: View {

    enum Size {
        /// Fenêtre d'accueil.
        case large
        /// Menu de la barre de menus, large de 280 points.
        case compact

        var logoSide: CGFloat { self == .large ? 96 : 52 }
        var title: Font { self == .large ? .largeTitle.weight(.semibold) : .title3.weight(.semibold) }
        var subtitle: Font { self == .large ? .callout : .caption }
        var spacing: CGFloat { self == .large ? 16 : 10 }
        var controlSize: ControlSize { self == .large ? .large : .regular }
    }

    var size: Size = .large
    /// Note affichée sous le bouton. Absente dans le menu, où la place manque.
    var showsHint = true
    let connect: () -> Void

    var body: some View {
        VStack(spacing: size.spacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size.logoSide, height: size.logoSide)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Notitime").font(size.title)
                Text("Mesurez combien de temps vous passez sur vos tâches")
                    .font(size.subtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: connect) {
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
            .controlSize(size.controlSize)

            if showsHint {
                Text("Dupliquez le template proposé, ou choisissez des pages existantes : "
                     + "Notitime reconnaîtra vos bases.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, size == .large ? 28 : 12)
    }
}
