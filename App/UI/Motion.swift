import SwiftUI

/// Réglages de mouvement partagés, repris des recettes de transitions.dev.
///
/// Une seule courbe pour tout l'onboarding : c'est ce qui fait qu'une suite
/// d'écrans se lit comme un seul geste plutôt que comme une succession
/// d'effets. Les durées viennent des recettes citées, à l'unité près.
enum Motion {

    /// `cubic-bezier(0.22, 1, 0.36, 1)` — la courbe commune aux recettes.
    static func ease(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    // « Page side-by-side »
    static let pageDuration: Double = 0.25
    static let pageDistance: CGFloat = 8
    static let pageBlur: CGFloat = 3

    // « Panel reveal »
    static let panelOpen: Double = 0.4
    static let panelBlur: CGFloat = 2

    // « Texts reveal »
    static let staggerDuration: Double = 0.5
    static let staggerDistance: CGFloat = 12
    static let staggerStep: Double = 0.04
    static let staggerBlur: CGFloat = 3

    // « Streaming text »
    static let wordGap: Double = 0.06
    static let wordFade: Double = 0.35
    static let wordBlur: CGFloat = 1
}

/// Décalage, opacité et flou appliqués ensemble — la combinaison que toutes ces
/// recettes emploient pour qu'un court déplacement se lise comme une entrée
/// franche.
struct Offset: ViewModifier {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var blur: CGFloat = 0
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .offset(x: x, y: y)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension AnyTransition {

    /// Deux écrans côte à côte : le sortant part d'un côté, l'entrant vient de
    /// l'autre, tous deux en fondu et en flou croisé.
    static func page(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: Offset(x: forward ? Motion.pageDistance : -Motion.pageDistance,
                               blur: Motion.pageBlur, opacity: 0),
                identity: Offset()),
            removal: .modifier(
                active: Offset(x: forward ? -Motion.pageDistance : Motion.pageDistance,
                               blur: Motion.pageBlur, opacity: 0),
                identity: Offset())
        )
    }

    /// Un bloc qui monte à sa place, flou puis net.
    static var rising: AnyTransition {
        .modifier(active: Offset(y: Motion.staggerDistance, blur: Motion.staggerBlur, opacity: 0),
                  identity: Offset())
    }

    /// Un panneau qui se déplie depuis le bas de son conteneur.
    static var panel: AnyTransition {
        .modifier(active: Offset(y: 40, blur: Motion.panelBlur, opacity: 0),
                  identity: Offset())
    }
}
