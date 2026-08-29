import SwiftUI

/// L'échelle typographique de l'application.
///
/// Six tailles, et pas une de plus. Chaque fois qu'une vue invente sa taille
/// sur place, l'écart avec la précédente devient une devinette : deux boutons
/// voisins finissent à 11 et 13 points sans que personne ne l'ait décidé. Les
/// vues piochent ici, et nulle part ailleurs.
enum Typography {

    /// Le chiffre qu'on vient lire, et rien d'autre autour.
    ///
    /// Au-delà de 20 points, le système compose en SF Pro Display : c'est la
    /// même police, dessinée pour les grandes tailles. Une seule vue s'en sert —
    /// la fin de session, où la durée travaillée est le sujet.
    static let display = Font.system(size: 34, weight: .bold)
    /// Le titre d'un panneau — un seul par écran.
    static let title = Font.system(size: 20, weight: .semibold)
    /// L'en-tête d'une feuille ou d'une section.
    static let heading = Font.system(size: 15, weight: .semibold)
    /// Le texte courant.
    static let body = Font.system(size: 13)
    /// Le libellé d'un bouton, d'un onglet, d'un champ.
    static let control = Font.system(size: 13, weight: .medium)
    /// Ce qui est cité dans une phrase : pastilles, touches, valeurs.
    static let compact = Font.system(size: 12, weight: .medium)
    /// Une précision, une mention discrète.
    static let caption = Font.system(size: 11)
}

extension View {

    /// Le libellé d'un bouton de feuille : même police, même hauteur.
    ///
    /// Les styles système ajustent leur gabarit à ce qu'on leur donne — un
    /// symbole dans le libellé suffit à grandir le bouton, et un
    /// `controlSize(.small)` isolé changeait la police d'un bouton sur deux.
    /// Une hauteur de libellé fixe rend tous les boutons d'une même feuille
    /// exactement aussi hauts, symbole ou non.
    func controlLabel() -> some View {
        font(Typography.control)
            .frame(height: 16)
    }
}

/// Les couleurs propres à l'application, celles que le système ne donne pas.
enum Palette {

    /// Le fond du panneau de la barre de menus.
    ///
    /// La couleur demandée (#f6f3f3) est claire : la reprendre telle quelle en
    /// thème sombre poserait du texte clair sur un fond clair. Elle vaut donc
    /// pour le thème clair, et son exacte contrepartie — même écart au fond
    /// système — pour le thème sombre.
    static let panel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
            : NSColor(red: 0.965, green: 0.953, blue: 0.953, alpha: 1)
    })
}
