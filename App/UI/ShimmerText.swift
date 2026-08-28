import SwiftUI

/// Libellé d'attente qui scintille, à la place d'une molette.
///
/// Transposition de la recette « shimmer text » de transitions.dev : le texte
/// est peint dans la couleur de base, et une bande de surbrillance quatre fois
/// plus large que lui traverse les glyphes en boucle. En CSS la bande est un
/// dégradé découpé par `background-clip: text` ; ici c'est un `LinearGradient`
/// masqué par le même `Text`, ce qui revient au même découpage.
///
/// Les couleurs de la recette (`#7c7c7c` / `#0d0d0d`) ne valent que pour un
/// fond clair : la doc invite à les accorder au thème, d'où `.secondary` et
/// `.primary`, qui suivent l'apparence système.
struct ShimmerText: View {

    let text: LocalizedStringKey
    /// Un titre, pas une légende : c'est ce qui remplace la molette.
    var font: Font = .title2.weight(.semibold)

    /// Réglages d'origine : `--shimmer-dur`, `--shimmer-band`, `--shimmer-ease`.
    private static let duration: Double = 2
    private static let band: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .foregroundStyle(.secondary)
            .overlay { sweep }
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sweep: some View {
        if !reduceMotion {
            ShimmerSweep()
                .mask(label)
                .allowsHitTesting(false)
        }
    }
}

/// La bande de surbrillance seule, à découper sur ce qu'on veut.
///
/// `background-position` va de `100 %` à `0 %` sur une bande de `400 %` : le
/// bord droit de la bande part collé au bord droit du texte — donc décalé de
/// trois largeurs vers la gauche — et finit aligné à gauche.
struct ShimmerSweep: View {

    var duration: Double = 2
    var band: CGFloat = 4

    @State private var swept = false

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.40),
                    .init(color: .primary, location: 0.50),
                    .init(color: .clear, location: 0.60),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * band)
            .offset(x: swept ? 0 : -geo.size.width * (band - 1))
            .animation(.linear(duration: duration).repeatForever(autoreverses: false),
                       value: swept)
        }
        .onAppear { swept = true }
    }
}
