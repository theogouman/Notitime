import AppKit
import SwiftUI

/// Le panneau de la barre de menus, vu de l'extérieur.
///
/// `MenuBarExtra` n'expose pas sa fenêtre : c'est son contenu qui la signale en
/// arrivant, et personne d'autre n'a à la deviner.
enum MenuBarPanel {

    /// La distance entre le bord droit du panneau et celui de l'écran.
    ///
    /// Zéro : le panneau fait angle droit avec l'écran. C'est ce coin — haut et
    /// droit — qui sert de point fixe à tout changement de taille.
    static let rightInset: CGFloat = 0

    /// La fenêtre du panneau, telle qu'elle s'est présentée.
    ///
    /// Elle était reconnue à sa géométrie : sans barre de titre, accrochée au
    /// bord haut de l'écran, large d'au moins 120 points. Or l'emplacement dans
    /// la barre de menus mesure exactement 120 points et répond aux mêmes
    /// critères — c'est lui qu'on fermait, et l'icône disparaissait de la barre.
    /// Le contenu du panneau sait dans quelle fenêtre il est posé : c'est à lui
    /// de le dire, plutôt qu'à une devinette.
    @MainActor private static weak var panel: NSWindow?

    /// Le panneau se signale en arrivant à l'écran.
    @MainActor
    static func remember(_ window: NSWindow) { panel = window }

    /// Referme le menu, comme un clic à côté.
    ///
    /// Ouvrir les réglages depuis le menu laissait les deux à l'écran : la
    /// fenêtre passait devant, le panneau restait derrière, et il fallait un clic
    /// de plus pour s'en débarrasser. Le panneau est retiré de l'écran, pas
    /// détruit : `close()` emporterait avec lui la place de l'application dans la
    /// barre de menus.
    @MainActor
    static func close() { panel?.orderOut(nil) }

    /// Ramène une fenêtre contre le coin supérieur droit de son écran.
    ///
    /// Laissé au système, le panneau se place sous l'icône : centré dessus tant
    /// qu'il tient, décalé vers la gauche quand il est large. Deux écrans de
    /// largeurs différentes s'ouvraient donc à deux endroits, et passer de l'un
    /// à l'autre donnait un mouvement de biais au lieu d'un simple changement de
    /// taille. Ancré à droite, le panneau ne bouge plus : seuls son bord gauche
    /// et son bas se déplacent.
    ///
    /// Le haut est ancré de la même façon, sous la barre de menus : une fenêtre
    /// grandit depuis son coin inférieur gauche, et le panneau serait monté
    /// derrière la barre en s'agrandissant.
    @MainActor
    static func anchorTopRight(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.maxX - rightInset - window.frame.width,
                             y: area.maxY - window.frame.height)
        // Sans ce garde-fou, notre propre déplacement relancerait la
        // notification qui nous a appelés.
        guard abs(window.frame.origin.x - origin.x) > 0.5
                || abs(window.frame.origin.y - origin.y) > 0.5 else { return }
        window.setFrameOrigin(origin)
    }
}

/// Redimensionne le panneau lui-même, image par image.
///
/// Le panneau ne changeait pas vraiment de taille : SwiftUI mesure une vue
/// d'après la valeur **finale** de son cadre, pas d'après la valeur intermédiaire
/// que l'animation dessine. La fenêtre sautait donc d'une taille à l'autre en une
/// image, et seul son contenu s'animait à l'intérieur — deux panneaux qui se
/// chevauchent, là où on n'en veut qu'un.
///
/// Le mouvement appartient donc à AppKit : la fenêtre est déplacée et
/// redimensionnée à chaque rafraîchissement de l'écran, sur la même courbe que le
/// reste de l'application, et la taille atteinte est rendue à SwiftUI qui remet
/// son contenu en page à cette taille-là. Une seule fenêtre, une seule taille à
/// tout instant.
///
/// Documenté chez Apple : `NSWindow.setFrame(_:display:)` pose la taille, une
/// image après l'autre. Deux raccourcis existent et ne conviennent pas.
/// `setFrame(_:display:animate:)` anime tout seul, mais sa durée ne se règle
/// qu'en sous-classant `NSWindow` — impossible ici, la fenêtre est celle de
/// `MenuBarExtra` — et sa courbe n'est pas la nôtre. `NSWindow.displayLink` bat
/// au rythme de l'écran, mais seulement tant que la fenêtre y est composée : un
/// banc d'essai l'a laissé muet, et un battement manqué laisserait le panneau à
/// mi-taille. La cadence vient donc d'une minuterie, posée dans tous les modes de
/// la boucle d'exécution — y compris celui d'un menu ouvert.
struct PanelResizer: NSViewRepresentable {

    /// La taille voulue par l'écran affiché, ou `nil` si le contenu décide.
    var target: CGSize?
    /// Faux quand le système demande de réduire les animations.
    var animates: Bool
    /// La taille atteinte, rendue à chaque image du mouvement.
    var onStep: (CGSize) -> Void

    func makeNSView(context: Context) -> NSView { ResizeView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ResizeView else { return }
        view.onStep = onStep
        view.animates = animates
        view.wanted = target
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? ResizeView)?.stop()
    }
}

/// La vue sans surface qui tient la fenêtre : elle ne dessine rien, elle sert
/// seulement à joindre la fenêtre que `MenuBarExtra` ne donne pas.
private final class ResizeView: NSView {

    var onStep: (CGSize) -> Void = { _ in }
    var animates = true

    var wanted: CGSize? {
        didSet {
            guard wanted != oldValue else { return }
            move(animated: animates && oldValue != nil)
        }
    }

    private var ticker: Timer?
    private var from: CGSize = .zero
    private var to: CGSize = .zero
    private var start: CFTimeInterval = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window else { return stop() }
        // Le déplacement compte autant que le redimensionnement : le système
        // repositionne le panneau sous l'icône à chaque ouverture.
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            center.addObserver(self, selector: #selector(anchor), name: name, object: window)
        }
        // C'est ici, et nulle part ailleurs, qu'on sait quelle fenêtre porte le
        // menu : le reste de l'application n'a plus à la deviner.
        MainActor.assumeIsolated { MenuBarPanel.remember(window) }
        move(animated: false)
    }

    /// Arrête le mouvement en cours, s'il y en a un.
    func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - Le mouvement

    private func move(animated: Bool) {
        stop()
        guard let window, let wanted else { return }
        let current = contentSize(of: window)
        guard animated, current != .zero, current != wanted else {
            // Hors animation, la taille part d'un cycle de rendu : la poser
            // depuis celui qui l'a demandée reviendrait à écrire un état de
            // SwiftUI au milieu de sa mise à jour.
            return DispatchQueue.main.async { [weak self] in self?.apply(wanted) }
        }
        from = current
        to = wanted
        start = CACurrentMediaTime()
        let ticker = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // `.common` plutôt que le mode par défaut : un menu ouvert fait tourner
        // la boucle dans son propre mode, et le mouvement s'y arrêterait net.
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func step() {
        let elapsed = CACurrentMediaTime() - start
        let time = min(1, elapsed / RootView.resize)
        let advance = Motion.curve.progress(time)
        apply(CGSize(width: from.width + (to.width - from.width) * advance,
                     height: from.height + (to.height - from.height) * advance))
        if time >= 1 { stop() }
    }

    /// Pose une taille sur la fenêtre, et la rend au contenu.
    private func apply(_ size: CGSize) {
        guard let window else { return }
        // Le contenu d'abord : il doit se remettre en page à la taille que la
        // fenêtre va prendre, pas à celle qu'elle quitte.
        onStep(size)
        let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        guard let screen = window.screen ?? NSScreen.main else {
            return window.setContentSize(size)
        }
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.maxX - MenuBarPanel.rightInset - frame.width,
                             y: area.maxY - frame.height)
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true)
    }

    private func contentSize(of window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    @objc private func anchor() {
        MainActor.assumeIsolated {
            guard let window else { return }
            MenuBarPanel.anchorTopRight(window)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        ticker?.invalidate()
    }
}
