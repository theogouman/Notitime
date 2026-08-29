import SwiftUI
import AppKit

/// Les images distantes déjà lues, gardées pour la durée de la session.
///
/// `AsyncImage` repart de zéro chaque fois que la vue qui le porte est
/// reconstruite : passer d'un onglet à l'autre suffisait à rejouer le squelette
/// et son fondu pour une icône affichée une seconde plus tôt. Le cache
/// d'`URLSession` évite le réseau, pas ce battement — c'est lui qu'on éteint.
///
/// `NSCache` est sûr entre files d'exécution : le cache se consulte donc dès la
/// construction de la vue, avant même son premier rendu. C'est la condition
/// pour que l'image soit déjà là, et qu'aucune animation n'ait lieu d'être.
final class ImageStore: @unchecked Sendable {

    static let shared = ImageStore()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        // Quelques icônes de workspace, pas une galerie.
        cache.countLimit = 32
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Lit l'image, du cache s'il l'a, du réseau sinon.
    func image(at url: URL) async -> NSImage? {
        if let cached = cached(url) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
