import AppKit
import SwiftUI

/// Menu contextuel du clic droit sur l'icône de la barre de menus.
///
/// `MenuBarExtra` n'expose pas son `NSStatusItem` : on ne peut donc pas lui
/// attacher un menu, et lui en attacher un remplacerait de toute façon le clic
/// gauche, qui ouvre le menu de session. On observe donc le clic droit **dans
/// notre propre processus** — un moniteur local, jamais global : aucun accès aux
/// événements des autres applications n'est demandé, et aucune autorisation
/// d'accessibilité n'est requise.
///
/// Le clic est reconnu à la fenêtre qui le reçoit : celle d'un élément de barre
/// de menus appartient à une classe privée dont le nom contient « StatusBar ».
/// Comparer le nom d'une classe privée est fragile ; c'est pourquoi l'événement
/// est **relayé tel quel** dès que le doute existe, laissant le comportement
/// d'origine intact plutôt que d'avaler un clic destiné à autre chose.
@MainActor
final class StatusItemContextMenu: NSObject {

    private var monitor: Any?
    private let openConfiguration: () -> Void
    private let quit: () -> Void

    init(openConfiguration: @escaping () -> Void, quit: @escaping () -> Void) {
        self.openConfiguration = openConfiguration
        self.quit = quit
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, StatusItemContextMenu.comesFromStatusItem(event) else { return event }
            self.present()
            return nil          // le clic est consommé : pas de second menu
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func comesFromStatusItem(_ event: NSEvent) -> Bool {
        guard let name = event.window?.className else { return false }
        return name.contains("StatusBar") || name.contains("MenuBarExtra")
    }

    private func present() {
        let menu = NSMenu()
        add("Réglages…", to: menu, keyEquivalent: ",", action: #selector(openSettings))
        add("À propos de Notitime", to: menu, keyEquivalent: "", action: #selector(showAbout))
        menu.addItem(.separator())
        add("Quitter Notitime", to: menu, keyEquivalent: "q", action: #selector(requestQuit))

        // `in: nil` situe le point à l'écran, ce qui est déjà le repère de
        // `mouseLocation` : le menu s'ouvre sous le curseur.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func add(_ title: String, to menu: NSMenu, keyEquivalent: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    @objc private func openSettings() {
        openConfiguration()
    }

    /// Panneau standard : il porte déjà l'icône, le nom et la version du bundle.
    /// L'application étant un agent, il faut l'activer pour qu'il passe devant.
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Notitime",
            .init(rawValue: "Copyright"): "Mesurez combien de temps vous passez sur vos tâches."
        ])
    }

    @objc private func requestQuit() {
        quit()
    }
}
