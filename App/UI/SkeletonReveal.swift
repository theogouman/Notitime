import SwiftUI

/// Réglages de la recette « skeleton loader and reveal » de transitions.dev.
enum SkeletonRevealMetrics {
    /// `--pulse-dur` : un aller-retour complet du battement.
    static let pulseDuration: Double = 1
    /// `--pulse-count` : le squelette bat une fois, puis attend.
    static let pulseCount = 1
    /// `--pulse-min` : opacité au creux du battement.
    static let pulseMin: Double = 0.5
    /// `--reveal-dur` : durée du fondu croisé.
    static let revealDuration: Double = 0.4
    /// `--reveal-blur` : flou porté par la couche qui n'est pas à sa place.
    static let revealBlur: CGFloat = 2
}

/// Un contenu chargé à distance qui apparaît sans à-coup.
///
/// Les deux couches occupent la même place : le squelette bat pendant l'attente,
/// puis les deux se croisent — le squelette s'efface en se floutant, le contenu
/// se pose en se dénettoyant, sur la même durée et la même courbe, pour que le
/// remplacement se lise comme un seul mouvement plutôt que comme deux.
///
/// Superposer plutôt que substituer évite le saut de mise en page qu'un simple
/// `if` provoquerait : la taille du bloc ne dépend jamais de l'état du réseau.
struct SkeletonReveal<Content: View, Placeholder: View>: View {

    /// Le contenu est-il arrivé ?
    let isRevealed: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            placeholder()
                // Le battement porte sa propre animation : la recette le place
                // sur les enfants du squelette pour que l'opacité du squelette
                // lui-même reste disponible pour le fondu.
                .opacity(pulsing ? SkeletonRevealMetrics.pulseMin : 1)
                .animation(pulse, value: pulsing)
                .opacity(isRevealed ? 0 : 1)
                .blur(radius: isRevealed ? SkeletonRevealMetrics.revealBlur : 0)

            content()
                .opacity(isRevealed ? 1 : 0)
                .blur(radius: isRevealed ? 0 : SkeletonRevealMetrics.revealBlur)
        }
        .animation(reveal, value: isRevealed)
        .task { await beat() }
    }

    private var reveal: Animation? {
        reduceMotion ? nil : .easeInOut(duration: SkeletonRevealMetrics.revealDuration)
    }

    private var pulse: Animation? {
        reduceMotion ? nil : .easeInOut(duration: SkeletonRevealMetrics.pulseDuration / 2)
    }

    /// Un aller-retour explicite plutôt qu'un `repeatCount` renversant : celui-ci
    /// termine sur la valeur de départ tout en laissant l'état sur celle
    /// d'arrivée, et le squelette resterait figé à mi-opacité.
    private func beat() async {
        guard !reduceMotion else { return }
        let half = SkeletonRevealMetrics.pulseDuration / 2
        for _ in 0..<SkeletonRevealMetrics.pulseCount {
            pulsing = true
            try? await Task.sleep(for: .seconds(half))
            pulsing = false
            try? await Task.sleep(for: .seconds(half))
        }
    }
}
