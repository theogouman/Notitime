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

    /// La même courbe, mais qu'on peut interroger point par point.
    ///
    /// Une `Animation` ne sert qu'à SwiftUI. Redimensionner une fenêtre est un
    /// geste AppKit : il faut savoir, à chaque image, où en est le mouvement.
    static let curve = UnitBezier(0.22, 1, 0.36, 1)

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

    // « Tabs sliding » — la pilule glisse d'un onglet à l'autre.
    static let tabsDuration: Double = 0.25

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

    /// « blur-out-up » : le texte sortant monte en se floutant, l'entrant arrive
    /// du bas, net. Un état d'envoi remplace le précédent — le mouvement dit
    /// qu'il s'agit du même endroit, pas d'une nouvelle ligne.
    static var blurOutUp: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: Offset(y: 8, opacity: 0), identity: Offset()),
            removal: .modifier(active: Offset(y: -8, blur: 4, opacity: 0), identity: Offset())
        )
    }

    /// Un panneau qui se déplie depuis le bas de son conteneur.
    static var panel: AnyTransition {
        .modifier(active: Offset(y: 40, blur: Motion.panelBlur, opacity: 0),
                  identity: Offset())
    }
}

/// Une courbe de Bézier unitaire, celle des feuilles de style.
///
/// Deux points de contrôle décrivent la courbe en fonction d'un paramètre, pas
/// du temps : trouver l'avancement à un instant donné demande donc de retrouver
/// d'abord ce paramètre. Newton s'en charge en quelques passes, et une
/// dichotomie prend le relais là où la pente s'annule.
struct UnitBezier {

    private let cx, bx, ax, cy, by, ay: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1
        bx = 3 * (x2 - x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    /// L'avancement — de 0 à 1 — après la fraction de temps écoulée.
    func progress(_ time: Double) -> Double {
        let time = min(max(0, time), 1)
        var t = time
        for _ in 0..<8 {
            let error = x(t) - time
            if abs(error) < 1e-5 { return y(t) }
            let slope = dx(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        var low = 0.0
        var high = 1.0
        t = time
        for _ in 0..<32 {
            let value = x(t)
            if abs(value - time) < 1e-5 { break }
            if value < time { low = t } else { high = t }
            t = (low + high) / 2
        }
        return y(t)
    }

    private func x(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func y(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
}
