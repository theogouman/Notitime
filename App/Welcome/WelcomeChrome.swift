import SwiftUI

/// Le bouton qui fait avancer l'accueil.
///
/// Un seul par écran, et toujours au même endroit : c'est ce qui permet de
/// traverser quatre écrans sans jamais chercher où cliquer.
struct PrimaryCTA: View {

    let title: LocalizedStringKey
    var showsNotionLogo = false
    var showsArrow = true
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                if showsNotionLogo {
                    Image("NotionLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                }
                if showsArrow {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        // La flèche avance d'un cheveu sous le curseur : le
                        // bouton dit alors ce qu'il fait avant qu'on ne clique.
                        .offset(x: hovered && !reduceMotion ? 3 : 0)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
            .background(
                Capsule().fill(Color.accentColor.opacity(hovered ? 0.88 : 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Entrée déclenche l'action principale de l'écran : traverser l'accueil
        // au clavier doit être possible d'un bout à l'autre.
        .keyboardShortcut(.defaultAction)
        .onHover { inside in
            guard !reduceMotion else { return hovered = inside }
            withAnimation(Motion.ease(0.18)) { hovered = inside }
        }
    }
}

/// Une carte de l'accueil : fond discret, coins continus, liseré léger.
struct WelcomeCard<Content: View>: View {
    var padding: CGFloat = 20
    /// Occupe toute la hauteur offerte : deux cartes côte à côte doivent finir
    /// à la même ligne, quelle que soit la longueur de leur texte.
    var stretches = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: stretches ? .infinity : nil,
                   alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }
    }
}

/// Une commande citée telle qu'elle apparaît dans Notion.
///
/// Police à chasse fixe embarquée, fond sombre à coins arrondis : la citation
/// se distingue d'elle-même, et les guillemets deviennent inutiles.
///
/// À la taille du texte qui l'entoure, et pas au-delà : la pastille cite une
/// commande au fil d'une phrase, elle ne l'annonce pas. Le fond suffit à la
/// détacher — l'agrandir en ferait un titre.
struct CodeChip: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.custom("JetBrainsMono-Medium", size: 11))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.14, blue: 0.17))
            )
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Emplacement d'une illustration à venir.
///
/// Une zone franchement vide plutôt qu'une image approximative : elle dit
/// qu'il manque quelque chose, et à quelle taille.
struct ImagePlaceholder: View {
    var ratio: CGFloat = 16 / 10
    var symbol = "photo"

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .aspectRatio(ratio, contentMode: .fit)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.quaternary)
            }
    }
}

/// Apparition décalée d'une suite de blocs — « texts reveal ».
///
/// Chaque bloc monte de 12 pt en se dénettoyant, le suivant partant 40 ms plus
/// tard : l'œil suit l'ordre de lecture au lieu de recevoir l'écran d'un bloc.
struct Staggered<Content: View>: View {
    let index: Int
    let shown: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content()
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : Motion.staggerDistance)
            .blur(radius: shown || reduceMotion ? 0 : Motion.staggerBlur)
            .animation(reduceMotion ? nil
                       : Motion.ease(Motion.staggerDuration)
                           .delay(Double(index) * Motion.staggerStep),
                       value: shown)
    }
}
