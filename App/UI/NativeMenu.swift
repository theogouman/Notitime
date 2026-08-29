import SwiftUI
import AppKit

/// Une entrée d'un menu natif : ce qu'on y lit, et ce que ça déclenche.
struct NativeMenuEntry: Identifiable {

    let id: String
    let title: String
    /// Symboles SF candidats, du plus précis au plus ancien : le premier que le
    /// système connaît est retenu. `arrow.trianglehead.2.clockwise.rotate.90`
    /// n'existe qu'à partir de macOS 15, et l'application descend jusqu'à 14 —
    /// une entrée sans image vaut mieux qu'une entrée manquante.
    var symbols: [String] = []
    /// Trait de séparation **au-dessus** de cette entrée : ce qui suit relève
    /// d'un autre registre.
    var startsSection = false
    /// Raccourci clavier, sans le modificateur — AppKit y ajoute Commande.
    var keyEquivalent: String = ""
    let action: () -> Void
}

/// Ouvre un menu AppKit sous la vue qui le porte.
///
/// `Menu` de SwiftUI confie son libellé **et ses entrées** à AppKit, qui n'en
/// retient que ce qu'il veut : sur macOS 15, une pastille dessinée en libellé
/// perd son fond et son liseré, et les images des `Label` d'un menu disparaissent
/// selon la version du système. En dessinant le libellé dans un simple `Button`
/// et en construisant le `NSMenu` nous-mêmes, plus rien n'est laissé à
/// l'interprétation : les images sont posées sur les `NSMenuItem`.
struct NativeMenuAnchor: NSViewRepresentable {

    /// Titre de la section, au-dessus des entrées : ouvert au milieu d'une
    /// phrase, le menu doit dire de quoi il parle. `nil` quand le bouton qui
    /// l'ouvre suffit à le dire.
    var header: String?
    let entries: [NativeMenuEntry]
    /// Ce que dit le menu quand il n'a rien à proposer. Un menu vide laisserait
    /// croire à une panne.
    var emptyTitle: String = ""
    /// Le menu s'aligne au moins sur la largeur de son ancre — inutile quand
    /// l'ancre est une simple icône, qui donnerait un menu ridiculement étroit.
    var matchesAnchorWidth = true
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> NSView { PassthroughView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.entries = entries
        guard isPresented else { return }
        // `popUp` bloque tant que le menu reste ouvert : on rend la main à
        // SwiftUI avant de l'appeler, sinon la mise à jour en cours ne se
        // termine qu'à la fermeture du menu.
        DispatchQueue.main.async {
            guard isPresented else { return }
            isPresented = false
            let menu = context.coordinator.menu(header: header, emptyTitle: emptyTitle)
            if matchesAnchorWidth { menu.minimumWidth = view.bounds.width }
            // Coordonnées non retournées : y négatif place le menu sous
            // l'ancre, au lieu de le poser par-dessus.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Une vue d'ancrage ne doit rien intercepter : le clic appartient au
    /// bouton SwiftUI qu'elle accompagne.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator: NSObject {

        var entries: [NativeMenuEntry] = []

        func menu(header: String?, emptyTitle: String) -> NSMenu {
            let menu = NSMenu()
            // Les entrées portent leur propre cible : sans cela AppKit les
            // désactive toutes en cherchant un répondant dans la chaîne.
            menu.autoenablesItems = false
            if let header { menu.addItem(.sectionHeader(title: header)) }
            if entries.isEmpty && !emptyTitle.isEmpty {
                let empty = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for (index, entry) in entries.enumerated() {
                if entry.startsSection && menu.numberOfItems > 0 {
                    menu.addItem(.separator())
                }
                let item = NSMenuItem(title: entry.title,
                                      action: #selector(pick(_:)),
                                      keyEquivalent: entry.keyEquivalent)
                item.target = self
                item.tag = index
                item.image = Coordinator.image(entry.symbols, describing: entry.title)
                menu.addItem(item)
            }
            return menu
        }

        /// La première image que le système sait dessiner, ou aucune.
        private static func image(_ symbols: [String], describing title: String) -> NSImage? {
            for name in symbols {
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: title) {
                    return image
                }
            }
            return nil
        }

        @objc private func pick(_ item: NSMenuItem) {
            guard entries.indices.contains(item.tag) else { return }
            entries[item.tag].action()
        }
    }
}
