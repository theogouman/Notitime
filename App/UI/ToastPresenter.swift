import SwiftUI
import AppKit

/// Ce qu'une annonce a à dire, et où elle en est de sa vie.
@MainActor
final class ToastModel: ObservableObject {
    @Published var text = ""
    /// Largeur de la carte : celle du menu, à laquelle elle s'aligne.
    @Published var width: CGFloat = 420
    /// Posée, ou en train d'entrer et de sortir.
    @Published var visible = false
    /// Le temps qu'il reste, de 1 à 0.
    @Published var progress: Double = 1
    /// Le geste offert avec l'annonce, s'il y en a un.
    @Published var undo: ToastUndo?
}

/// Un retour en arrière proposé dans une annonce.
struct ToastUndo {
    let title: String
    let symbol: String
    let perform: @MainActor () -> Void
}

/// Les annonces, dans leur propre fenêtre, sous celle du menu.
///
/// Elles vivaient jusqu'ici **dans** le panneau : une ligne de texte posée sous
/// les contrôles, que rien n'effaçait. Un message d'inactivité restait donc
/// affiché sur tous les écrans, longtemps après le fait qu'il annonçait — et il
/// prenait la place de ce qu'on était venu faire.
///
/// Une annonce est un événement : elle apparaît, se lit, et s'en va. Elle
/// n'appartient pas au panneau, qui a sa propre vie et se referme au premier
/// clic à côté ; elle se pose donc juste en dessous, alignée sur lui, comme un
/// second morceau de l'extension, et survit à sa fermeture.
@MainActor
final class ToastPresenter {

    static let shared = ToastPresenter()

    private let model = ToastModel()
    private var panel: NSPanel?
    private var countdown: Task<Void, Never>?

    /// L'espace entre le bas du menu et le haut de la carte.
    private static let gap: CGFloat = 8
    /// Le nom de notre fenêtre d'annonce : c'est à lui que `MenuBarPanel` la
    /// reconnaît pour ne pas la fermer avec le menu.
    static let panelIdentifier = NSUserInterfaceItemIdentifier("notitime.toast")
    /// Durées d'entrée et de sortie.
    private static let entrance: Double = 0.28
    private static let exit: Double = 0.22
    /// Pas du décompte : trente fois par seconde, la bande se vide sans à-coup
    /// et le survol est vu presque tout de suite.
    private static let tick: Double = 1.0 / 30

    /// Le temps de lire, sans plus : un fond de quatre secondes, et de quoi lire
    /// les phrases longues sans les précipiter.
    ///
    /// Une annonce qui propose un geste tient plus longtemps : il faut la lire,
    /// décider, viser. Quatre secondes suffisent à comprendre qu'une tâche a
    /// disparu, pas à changer d'avis.
    private static func lifetime(of text: String, offering undo: Bool) -> Double {
        let read = min(9, max(4, Double(text.count) * 0.06))
        return undo ? max(7, read) : read
    }

    private init() {}

    /// Montre une annonce, en remplaçant celle qui s'affichait éventuellement.
    func show(_ text: String, undo: ToastUndo? = nil) {
        countdown?.cancel()

        let anchor = anchorFrame()
        model.text = text
        model.width = anchor.cardWidth
        model.visible = false
        model.progress = 1
        model.undo = undo

        let panel = panel ?? makePanel()
        self.panel = panel
        // Une annonce sans geste ne se clique pas : les événements la traversent
        // et atteignent ce qu'il y a derrière. Une annonce qui propose un retour
        // en arrière doit, elle, pouvoir être visée.
        panel.ignoresMouseEvents = undo == nil
        let card = ToastHostingView(rootView: ToastCard(model: model))
        card.layoutSubtreeIfNeeded()
        let size = card.fittingSize
        panel.contentView = card
        panel.setContentSize(size)
        panel.setFrameTopLeftPoint(anchor.topLeft(for: size))
        // Jamais `makeKeyAndOrderFront` : prendre le focus refermerait le
        // panneau du menu, qui se ferme dès qu'il le perd.
        panel.orderFrontRegardless()

        let seconds = ToastPresenter.lifetime(of: text, offering: undo != nil)
        // L'état de départ doit être vu comme tel : posé dans le même tour de
        // boucle que l'arrivée, rien ne s'animerait.
        DispatchQueue.main.async { [model] in
            withAnimation(Motion.ease(ToastPresenter.entrance)) { model.visible = true }
        }

        // Une annonce née le panneau ouvert appartient à ce qu'on était en train
        // de faire : elle s'en va avec lui. Une annonce née panneau fermé — un
        // pomodoro qui se termine — n'a personne pour la refermer et vit sa vie.
        let followsPanel = MenuBarPanel.isOpen
        countdown = Task { [weak self] in
            await self?.countDown(from: seconds, followingPanel: followsPanel)
        }
    }

    /// Le décompte, mené à la main plutôt que confié à une animation.
    ///
    /// Une animation linéaire ne se suspend pas : il faudrait l'arrêter et la
    /// relancer à chaque entrée et sortie du curseur, en recalculant sa durée.
    /// Ici la bande n'est qu'un état, et le temps ne s'écoule que lorsqu'on ne
    /// lit pas — le curseur posé sur la carte suspend tout, et rien ne disparaît
    /// sous le geste qui allait la viser.
    private func countDown(from total: Double, followingPanel: Bool) async {
        var remaining = total
        while remaining > 0 {
            try? await Task.sleep(for: .seconds(ToastPresenter.tick))
            guard !Task.isCancelled else { return }
            guard !(followingPanel && !MenuBarPanel.isOpen) else { return hide() }
            guard !pointerIsOver else { continue }
            remaining -= ToastPresenter.tick
            model.progress = max(0, remaining / total)
        }
        hide()
    }

    /// Le curseur est posé sur la carte — sur la carte elle-même, pas sur la
    /// marge transparente qui loge son ombre.
    private var pointerIsOver: Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: ToastCard.margin, dy: ToastCard.margin)
            .contains(NSEvent.mouseLocation)
    }

    /// Efface l'annonce, puis retire la fenêtre une fois la sortie jouée.
    func hide() {
        countdown?.cancel()
        countdown = nil
        guard let panel, panel.isVisible else { return }
        withAnimation(Motion.ease(ToastPresenter.exit)) { model.visible = false }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ToastPresenter.exit + 0.05))
            // Une annonce arrivée entre-temps a repris la fenêtre : on la laisse.
            guard let self, !Task.isCancelled, !self.model.visible else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.identifier = ToastPresenter.panelIdentifier
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // l'ombre est dessinée par la carte
        panel.isMovable = false
        // Réglé à chaque annonce : seule celle qui offre un geste se clique.
        panel.ignoresMouseEvents = true
        // Elle suit l'utilisateur d'un bureau à l'autre et survit au plein écran.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    // MARK: - Où se poser

    /// De quoi aligner la carte sur le menu : sa largeur, son bord gauche, et le
    /// bas duquel elle doit pendre.
    private struct Anchor {
        let cardWidth: CGFloat
        let left: CGFloat
        let bottom: CGFloat

        /// Le coin supérieur gauche de la **fenêtre** : la carte y est enfoncée
        /// de sa marge, celle qui loge l'ombre.
        func topLeft(for size: CGSize) -> NSPoint {
            NSPoint(x: left - ToastCard.margin,
                    y: bottom - ToastPresenter.gap + ToastCard.margin)
        }
    }

    /// La carte reprend la largeur et le bord gauche du menu quand il est
    /// ouvert ; sinon elle garde la largeur du panneau et se range sous l'icône.
    ///
    /// `MenuBarExtra` n'expose ni son panneau ni son `NSStatusItem` : on les
    /// reconnaît à leur position — accrochés au bord haut de l'écran — et on
    /// retient le plus large, qui est le panneau quand il est ouvert et l'icône
    /// quand il est fermé. Aucun nom de classe privée n'est comparé ici : la
    /// géométrie ne change pas d'une version de macOS à l'autre.
    private func anchorFrame() -> Anchor {
        let screen = anchorScreen()
        let stored = ToastPresenter.storedPanelWidth
        let top = screen.frame.maxY

        let candidate = NSApp.windows
            .filter { window in
                window !== panel && window.isVisible
                    && window.frame.maxY >= top - 40 && window.frame.width > 20
            }
            .max { $0.frame.width < $1.frame.width }?
            .frame

        guard let candidate else {
            let frame = screen.visibleFrame
            return Anchor(cardWidth: stored,
                          left: frame.maxX - MenuBarPanel.rightInset - stored,
                          bottom: frame.maxY)
        }
        // Le menu ouvert donne sa largeur et son bord ; l'icône seule ne dit
        // rien de la largeur voulue, la carte reprend alors celle du panneau et
        // se range là où celui-ci s'ouvrirait — contre le bord droit.
        let isPanel = candidate.width >= 120
        let width = isPanel ? candidate.width : stored
        let right = isPanel ? candidate.maxX
                            : screen.visibleFrame.maxX - MenuBarPanel.rightInset
        let bounded = max(screen.visibleFrame.minX, right - width)
        return Anchor(cardWidth: width, left: bounded, bottom: candidate.minY)
    }

    /// L'écran qui porte la barre de menus où vit l'icône.
    private func anchorScreen() -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// La largeur de repli, menu fermé : celle des écrans de session. Une
    /// annonce reçue panneau fermé concerne presque toujours une session, et la
    /// largeur de la liste ferait une carte démesurée sous l'icône.
    private static var storedPanelWidth: CGFloat { RootView.compactSize.width }
}

/// La carte : un texte, sur le fond du panneau, sous une bande qui se vide.
struct ToastCard: View {

    @ObservedObject var model: ToastModel

    /// La marge autour de la carte, dans laquelle l'ombre se dessine et par
    /// laquelle la carte entre et sort.
    ///
    /// Elle doit dépasser la portée de l'ombre — rayon plus décalage — sinon la
    /// fenêtre la coupe net, et le dégradé s'arrête sur une arête droite au lieu
    /// de se fondre dans le fond. C'était le cas à 14 points pour une ombre qui
    /// en portait 18.
    static let margin: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            countdown
            // Côte à côte tant que la carte est large — c'est celle du menu, qui
            // vaut 630 points sur la liste des tâches. Sous cette largeur, un
            // libellé de bouton un peu long réduisait le message à trois mots
            // par ligne : la carte se déplie alors sur deux étages.
            Group {
                if model.width >= ToastCard.sideBySide {
                    HStack(spacing: 8) { message; action }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        message
                        action.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: model.width)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        // Deux ombres : une courte qui pose la carte, une longue et diffuse qui
        // la fait flotter. Une seule ombre large donne le halo gris qu'on voyait.
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 7)
        // Elle descend de sous le menu, et repart par où elle est venue.
        .offset(y: model.visible ? 0 : -8)
        .opacity(model.visible ? 1 : 0)
        .padding(ToastCard.margin)
    }

    /// Largeur à partir de laquelle le geste tient sur la même ligne que le
    /// message.
    static let sideBySide: CGFloat = 420

    private var message: some View {
        Text(verbatim: model.text)
            .font(Typography.compact)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var action: some View {
        if let undo = model.undo {
            Button {
                undo.perform()
                ToastPresenter.shared.hide()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: undo.symbol)
                    Text(verbatim: undo.title)
                }
                .font(Typography.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusEffectDisabled()
            .fixedSize()
        }
    }

    /// La tranche supérieure : pleine à l'arrivée, vide au départ. Elle dit
    /// combien de temps il reste à lire, plutôt que de laisser la carte
    /// disparaître sans prévenir.
    private var countdown: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.85))
            .frame(height: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: max(0, model.progress), anchor: .leading)
    }
}

/// La vue d'accueil de la carte, qui répond au premier clic.
///
/// Une fenêtre qui n'est pas au premier plan avale le clic qui l'y amènerait :
/// il faudrait cliquer deux fois sur « Annuler », et le premier clic refermerait
/// le menu. Ici, le premier clic agit — c'est tout l'intérêt d'un geste offert
/// pendant quelques secondes.
private final class ToastHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
