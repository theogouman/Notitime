import SwiftUI
import AVFoundation

/// Une vidéo muette qui tourne en boucle, sans aucune commande.
///
/// Une démonstration de quelques secondes n'a pas à être lancée : elle se
/// regarde comme une image animée. Pas de son — un guide qui se met à parler
/// sans prévenir est une mauvaise surprise —, pas de barre de lecture, et une
/// boucle sans couture (`AVPlayerLooper`) plutôt qu'un redémarrage visible.
struct LoopingVideo: NSViewRepresentable {

    let url: URL

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.start(url: url)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {}

    /// La feuille refermée, la lecture s'arrête : sans cela le décodage
    /// continue en fond, invisible et pour rien.
    static func dismantleNSView(_ view: PlayerView, coordinator: ()) {
        view.stop()
    }

    final class PlayerView: NSView {

        private let playerLayer = AVPlayerLayer()
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // Jamais rognée : le cadrage de la démonstration est ce qu’elle montre.
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            // Le calque ne participe pas à la mise en page : on le recale nous
            // mêmes, sans animation, sinon il glisse à chaque redimensionnement.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func start(url: URL) {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerLayer.player = player
            self.player = player
            player.play()
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            playerLayer.player = nil
            player = nil
            looper = nil
        }
    }
}
