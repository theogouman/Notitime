import SwiftUI
import AppKit

/// Fenêtre d'accueil du premier lancement.
///
/// Distincte de la fenêtre de configuration : celle-ci est un formulaire, celle
/// -là une présentation. Les mêler obligerait l'une des deux à porter les
/// contraintes de l'autre — une largeur de formulaire pour un récit, ou des
/// onglets au milieu d'un accueil.
enum WelcomeWindow {

    static let id = "notitime.welcome"

    /// Rectangulaire et large : le texte d'accueil se lit sur des lignes
    /// courtes, et la grille de présentation a besoin de trois colonnes.
    static let size = CGSize(width: 1040, height: 720)

    @MainActor
    static func window() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && (window.identifier?.rawValue.contains(id) == true
                    // Une fenêtre sans barre de titre garde son titre : il sert
                    // de repli si SwiftUI ne pose pas l'identifiant attendu.
                    || window.title == "Bienvenue dans Notitime")
        }
    }

    @MainActor
    static func present(_ openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func close() {
        window()?.close()
    }
}

/// Ouverture du menu de la barre de menus depuis le code.
///
/// SwiftUI n'expose rien pour cela : `MenuBarExtra` s'ouvre au clic, et à rien
/// d'autre. On retrouve donc le bouton de l'emplacement et on lui adresse le
/// clic qu'aurait fait l'utilisateur. La recherche est prudente — la propriété
/// interrogée n'est pas publique — et un échec ne coûte rien : l'accueil se
/// termine, l'utilisateur ouvre le menu lui-même.
@MainActor
enum StatusItemOpener {

    @discardableResult
    static func open() -> Bool {
        let selector = Selector(("statusItem"))
        for window in NSApp.windows where window.responds(to: selector) {
            guard let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem,
                  let button = item.button else { continue }
            button.performClick(nil)
            return true
        }
        return false
    }
}
