import SwiftUI
import SwiftData
import AppKit
import Combine
import NotitimeCore

/// Point d'entrée. L'application vit dans la barre de menus : aucune fenêtre
/// principale, aucune icône dans le Dock (principe I, `LSUIElement`).
@main
struct NotitimeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var root = RootState()

    var body: some Scene {
        MenuBarExtra {
            RootView(state: root)
                .modelContainer(root.containerOrEmpty)
        } label: {
            // FR-025 : au repos l'icône seule ; en session, le temps restant et
            // le nom court de la tâche.
            MenuBarLabel(state: root)
        }
        .menuBarExtraStyle(.window)

        // Accueil du premier lancement : rectangulaire, centré, et bien plus
        // large que la fenêtre de configuration — un récit ne se lit pas dans un
        // formulaire.
        Window("Bienvenue dans Notitime", id: WelcomeWindow.id) {
            WelcomeView(state: root)
                .modelContainer(root.containerOrEmpty)
        }
        .defaultSize(width: WelcomeWindow.size.width, height: WelcomeWindow.size.height)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // Fenêtre à la demande : elle n'existe que si l'utilisateur l'ouvre, ce
        // que le principe I autorise — il ne proscrit qu'une fenêtre permanente.
        Window("Réglages de Notitime", id: ConfigurationWindow.id) {
            ConfigurationView(state: root)
                .modelContainer(root.containerOrEmpty)
        }
        .defaultSize(width: ConfigurationView.size.width, height: ConfigurationView.size.height)
        // Taille fixe : la vue porte sa dimension, la fenêtre s'y tient.
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // FR-035 : une seule instance. Activer celle qui tourne déjà est le
        // comportement attendu quand l'utilisateur relance l'app parce qu'il ne
        // l'a pas vue dans la barre de menus. Pas de fichier verrou : il
        // survivrait à un arrêt inopiné et bloquerait le relancement (R-10).
        if let running = SingleInstanceGuard.otherRunningInstance() {
            running.activate(options: [])
            SingleInstanceGuard.presentAlreadyRunningNotice()
            NSApp.terminate(nil)
        }
    }
}

enum SingleInstanceGuard {

    static func otherRunningInstance() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let current = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != current.processIdentifier }
    }

    static func presentAlreadyRunningNotice() {
        let alert = NSAlert()
        alert.messageText = String(localized: "app.alreadyRunning")
        alert.alertStyle = .informational
        alert.runModal()
    }
}

/// État racine : câblage, puis revalidation des rôles au démarrage.
@MainActor
final class RootState: ObservableObject {

    @Published private(set) var startupMessage: String?
    /// L'accueil ne s'ouvre qu'une fois par lancement : le rouvrir à chaque
    /// réapparition du libellé le ferait resurgir sans qu'on l'ait demandé.
    var hasPresentedOnboarding = false
    private(set) var environment: AppEnvironment?
    private(set) var onboarding: OnboardingModel?

    private(set) var session: SessionController?

    /// Republié depuis les modèles enfants : le menu doit se redessiner quand la
    /// configuration progresse dans la fenêtre ou qu'une session avance.
    private var observations: [AnyCancellable] = []

    init() {
        do {
            let environment = try AppEnvironment()
            self.environment = environment
            let onboarding = OnboardingModel(environment: environment)
            self.onboarding = onboarding
            let session = SessionController(environment: environment)
            self.session = session
            observations = [
                onboarding.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
                // Les annonces vivent hors du panneau : leur affichage ne peut
                // pas dépendre d'une vue qui n'existe que menu ouvert — un
                // pomodoro se termine le plus souvent alors qu'il est fermé.
                session.$toast.compactMap { $0 }.sink { toast in
                    ToastPresenter.shared.show(toast.text,
                                               undo: toast.undo.map { undo in
                        ToastUndo(title: undo.title, symbol: undo.symbol,
                                  perform: undo.perform)
                    })
                }
            ]
            // FR-009 — les tâches se chargent dès que la configuration le
            // permet, sans attendre l'ouverture du menu ni un relancement.
            onboarding.onReady = { [weak session] in await session?.loadTasks() }
            onboarding.restoreFromPersistence()
            Task {
                // Repère de lancement : sans lui, deux lignes identiques à
                // quelques secondes d'écart ne disent pas si l'application a
                // redémarré entre les deux — question qu'on s'est posée.
                await environment.log.log(.app, "démarrage pid=\(ProcessInfo.processInfo.processIdentifier) "
                                          + "version=\(AppEnvironment.shortVersion)")
                await session.applySettings()
                await validateAtStartup(environment)
                // Une session retrouvée reprend la main avant toute autre chose :
                // son état est déjà persisté, l'écran doit le refléter (FR-022).
                await session.restore()
                if onboarding.isConfigured { await session.loadTasks() }
                // US6.2 — ce qui restait en file repart au lancement.
                await session.drainOutbox()
            }
        } catch {
            startupMessage = error.localizedDescription
        }
    }

    /// Vrai quand Notitime a de quoi travailler : une connexion et les rôles
    /// indispensables liés.
    var isConfigured: Bool { readiness == .ready }

    /// Une seule lecture de la situation pour toutes les surfaces.
    var readiness: AppReadiness { onboarding?.readiness ?? .needsConnection }

    /// Où mène le lancement — l'accueil, la configuration, ou nulle part.
    var destination: StartupDestination { StartupDestination.decide(for: readiness) }


    /// Cas limite « quitter l'app volontairement » : une session en cours suit
    /// la règle de son mode. On ne quitte jamais en perdant du temps travaillé.
    func requestTermination() {
        guard let session, session.hasRunningSession else { return NSApp.terminate(nil) }

        let alert = NSAlert()
        alert.messageText = "Une session est en cours"
        alert.informativeText = "Quitter maintenant la clôturera et enverra l'entrée "
            + "correspondante dans Notion."
        alert.addButton(withTitle: "Clôturer et quitter")
        alert.addButton(withTitle: "Annuler")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await session.stop()
            // L'envoi est détaché : on lui laisse le temps d'aboutir.
            await session.drainOutbox()
            NSApp.terminate(nil)
        }
    }

    var containerOrEmpty: ModelContainer {
        // Sans magasin, l'app ne peut rien faire d'utile ; on rend tout de même
        // un conteneur pour que la vue s'affiche et explique le problème.
        environment?.container ?? ((try? NotitimeStore.makeInMemoryContainer())!)
    }

    /// T043 — la validation de schéma échoue au démarrage plutôt qu'au moment
    /// d'envoyer une entrée, quand il serait trop tard.
    private func validateAtStartup(_ environment: AppEnvironment) async {
        switch await StartupValidation(environment: environment).run() {
        case .valid, .notConfigured:
            startupMessage = nil
        case .needsRemapping(let role, _):
            startupMessage = "Le schéma de la base \(role.rawValue) a changé. "
                + "Ouvrez les réglages pour re-mapper les propriétés."
        case .needsSourceChoice(let role, _):
            startupMessage = "La base \(role.rawValue) contient plusieurs sources de données. "
                + "Ouvrez les réglages pour choisir celle à utiliser."
        case .unreachable:
            // Notion injoignable n'invalide rien : le cache reste utilisable.
            startupMessage = nil
        }
    }
}

/// Contenu du menu de la barre de menus.
///
/// Volontairement sans formulaire : le menu se ferme au clic, ce qui convient à
/// une commande immédiate mais pas à une configuration en plusieurs étapes.
/// Celle-ci ouvre la fenêtre dédiée. Le menu accueillera la liste des tâches et
/// les contrôles de session à l'US2 (FR-015, FR-025).
struct RootView: View {
    @ObservedObject var state: RootState
    @Environment(\.openWindow) private var openWindow
    /// Le menu des options est ouvert, ou sur le point de l'être.
    @State private var showsOptions = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Le panneau de la liste des tâches.
    ///
    /// 630 × 430 : de quoi parcourir une dizaine de tâches avec leur projet et
    /// leur échéance, et écrire une nouvelle tâche sans que la ligne se serre.
    static let listSize = CGSize(width: 630, height: 430)

    /// Le panneau de tous les autres écrans.
    ///
    /// 320 × 370 : un compteur, une question, une confirmation. Aucun de ces
    /// écrans n'a de liste à dérouler, et la largeur de la liste les laissait
    /// flotter au milieu du vide.
    static let compactSize = CGSize(width: 320, height: 370)

    /// La taille que l'écran affiché réclame, ou `nil` tant qu'aucun compte
    /// n'est relié — il n'y a alors qu'un bouton, et 370 points de vide en
    /// dessous ne diraient rien de plus.
    private var targetSize: CGSize? {
        guard state.readiness == .ready else { return nil }
        return state.session?.showsTaskList == true ? RootView.listSize : RootView.compactSize
    }

    /// La taille qu'a le panneau **en ce moment**.
    ///
    /// Elle n'est plus décidée ici : c'est la fenêtre qui change de taille, et
    /// elle rend à chaque image celle qu'elle vient de prendre. Le contenu se
    /// remet donc en page à la taille réelle du panneau, au lieu d'être mis en
    /// page à la taille finale dans une fenêtre qui, elle, avait déjà sauté.
    @State private var panelSize = RootView.compactSize

    private var width: CGFloat {
        targetSize == nil ? RootView.compactSize.width : panelSize.width
    }

    private var panelHeight: CGFloat? {
        targetSize == nil ? nil : panelSize.height
    }

    /// Durée du changement de taille, reprise telle quelle de la recette.
    static let resize: Double = 0.3

    /// Hauteur du pied : le trait (1), ses marges (6 et 6) et le bouton (20).
    ///
    /// Elle est nommée parce qu'elle se retranche : le contenu occupe la hauteur
    /// du panneau moins celle du pied, et le total reste exactement celui
    /// annoncé par `panelSize`.
    private static let footerHeight: CGFloat = 33

    /// Ce qui reste au contenu une fois le pied réservé.
    private var contentHeight: CGFloat? {
        panelHeight.map { $0 - RootView.footerHeight }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = state.startupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            content
                .frame(maxWidth: .infinity,
                       maxHeight: panelHeight == nil ? nil : .infinity,
                       alignment: .topLeading)
                // L'écran sortant s'efface pendant que le cadre glisse, et
                // l'entrant se pose dedans : sans ce fondu, le contenu changeait
                // d'un coup au milieu d'un mouvement, et c'est ce à-coup qu'on
                // prenait pour une absence d'animation.
                .transition(.opacity)
                .animation(reduceMotion ? nil : Motion.ease(RootView.resize),
                           value: targetSize)
        }
        .padding(12)
        .frame(width: width, height: contentHeight, alignment: .topLeading)
        // Le pied est ancré au bas du panneau, quoi qu'il arrive au-dessus.
        //
        // Empilé à la suite du contenu, il était poussé hors du cadre dès que
        // celui-ci réclamait plus de place que le panneau n'en a — un avis de
        // fin de session, une ligne d'écriture de tâche — et le bouton des
        // réglages disparaissait. En marge basse, il vient **après** la hauteur
        // du contenu : le contenu ne peut plus le repousser, et ce qui déborde
        // passe derrière lui.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        // Un fond à nous plutôt que celui du système : le panneau doit se
        // reconnaître, et non se confondre avec n'importe quel menu.
        .background(Palette.panel)
        // La fenêtre elle-même change de taille, largeur et hauteur ensemble,
        // sur 300 ms et sur la courbe commune à l'application (recette « card
        // resize » de transitions.dev). Elle reste collée au coin supérieur
        // droit de l'écran : c'est le point fixe du mouvement.
        .background(
            PanelResizer(target: targetSize,
                         animates: !reduceMotion,
                         onStep: { panelSize = $0 })
                .frame(width: 0, height: 0)
        )
        // Ce qui déborde est rogné, jamais poussé dehors.
        .clipped()
    }

    /// Le bas du panneau : la poignée, un trait, et les options.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                options
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        // Opaque : le contenu qui déborde passe derrière lui, sans le traverser.
        .background(Palette.panel)
    }

    @ViewBuilder
    private var content: some View {
        switch state.readiness {
        case .needsConnection:
            // Rien d'autre n'est proposé : démarrer une session sans compte
            // relié produirait une entrée que rien ne pourrait envoyer.
            ConnectPromptView(size: .compact, showsHint: false) {
                ConfigurationWindow.present(openWindow)
                Task { await state.onboarding?.connect() }
            }

        case .needsBinding:
            VStack(alignment: .leading, spacing: 10) {
                summary
                Button("Terminer la configuration…") {
                    ConfigurationWindow.present(openWindow)
                }
                .buttonStyle(.borderedProminent)
            }

        case .ready:
            // Le workspace relié ne se dit plus ici : c'est une information
            // de réglages, et elle prenait la première ligne du menu à
            // chaque ouverture pour ne rien apprendre.
            if let session = state.session {
                SessionControls(controller: session)
            }
        }
    }

    /// Actualiser, Réglages et Quitter, repliés derrière un seul bouton.
    ///
    /// Trois boutons pleine largeur pour des commandes qu'on emploie une fois
    /// par jour prendraient autant de place que ce qui sert à chaque ouverture.
    /// Le menu est construit en AppKit : confié à SwiftUI, il perdait les images
    /// de ses entrées d'une version de macOS à l'autre (voir `NativeMenuAnchor`).
    private var options: some View {
        Button { showsOptions = true } label: {
            Image(systemName: "ellipsis.circle")
                .font(Typography.control)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(
            NativeMenuAnchor(entries: optionEntries,
                             matchesAnchorWidth: false,
                             isPresented: $showsOptions)
        )
        .help("Autres options")
        .accessibilityLabel("Autres options")
    }

    private var optionEntries: [NativeMenuEntry] {
        var entries: [NativeMenuEntry] = []
        // Recharger les tâches est la seule commande qui agit sur ce qu'on a
        // sous les yeux : elle est en tête, et détachée des deux autres.
        if state.readiness == .ready, let session = state.session {
            entries.append(NativeMenuEntry(
                id: "refresh",
                title: String(localized: "Actualiser les tâches"),
                symbols: ["arrow.trianglehead.2.clockwise.rotate.90",
                          "arrow.triangle.2.circlepath"]) {
                    Task { await session.loadTasks() }
                })
        }
        entries.append(NativeMenuEntry(
            id: "settings",
            title: String(localized: "Réglages…"),
            symbols: ["gear"],
            startsSection: true) {
                ConfigurationWindow.present(openWindow)
                // Le menu a fini son travail : la suite se passe dans la
                // fenêtre, et le laisser ouvert derrière elle n'apporte rien.
                MenuBarPanel.close()
            })
        entries.append(NativeMenuEntry(
            id: "quit",
            title: String(localized: "Quitter"),
            symbols: ["xmark.circle"],
            keyEquivalent: "q") {
                state.requestTermination()
            })
        return entries
    }

    @ViewBuilder
    private var summary: some View {
        if state.onboarding == nil {
            Text("Notitime n'a pas pu démarrer.").font(.callout)
        } else {
            Text("Connecté, mais il reste des bases à désigner.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}



/// Libellé de la barre de menus (FR-025).
///
/// L'icône est toujours là, le texte dit l'état. Un gabarit monochrome de 18 pt
/// ne peut porter que sa silhouette : la décliner par état la rendrait moins
/// reconnaissable sans rien gagner en information, que le texte porte déjà.
struct MenuBarLabel: View {

    /// Largeur de l'emplacement dans la barre de menus.
    static let width: CGFloat = 120

    @ObservedObject var state: RootState
    @Environment(\.openWindow) private var openWindow
    /// Retenu par la vue : un moniteur d'événements libéré cesse d'observer.
    @State private var contextMenu: StatusItemContextMenu?

    var body: some View {
        HStack(spacing: 4) {
            Image("MenuBarIcon")
                // Le catalogue déclare déjà l'intention « gabarit » ; le répéter
                // ici garantit la teinte automatique quel que soit le rendu.
                .renderingMode(.template)
            if let label = trailing {
                Text(label)
                    // Chiffres à chasse fixe : sans cela la largeur du libellé
                    // change à chaque seconde, et l'icône se déplace avec.
                    .monospacedDigit()
            }
        }
        // Largeur fixe, réservée même au repos : l'emplacement ne se réajuste
        // plus au démarrage et à l'arrêt d'une session — les icônes voisines
        // restaient sinon à leur place, mais la nôtre glissait sous le curseur.
        .frame(width: MenuBarLabel.width)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            // Sans compte relié il n'y a rien à faire dans le menu : on ouvre
            // une fenêtre. Laquelle, c'est `StartupDestination` qui le dit.
            if !state.hasPresentedOnboarding {
                state.hasPresentedOnboarding = true
                switch state.destination {
                case .welcome: WelcomeWindow.present(openWindow)
                case .configuration: ConfigurationWindow.present(openWindow)
                case .nothing: break
                }
            }

            guard contextMenu == nil else { return }
            let menu = StatusItemContextMenu(
                openConfiguration: { ConfigurationWindow.present(openWindow) },
                quit: { state.requestTermination() }
            )
            menu.install()
            contextMenu = menu
        }
    }

    /// Ce qui suit l'icône, ou rien quand rien ne tourne.
    private var trailing: String? {
        switch state.session?.phase {
        case .running(let remaining, let taskPageID):
            let controller = state.session
            // Le suivi libre n'a pas de cible : c'est le temps écoulé qui compte.
            let time = remaining.map(SessionControls.format) ?? controller?.elapsedLabel ?? "00:00"
            let marker = (controller?.isPaused ?? false) ? "⏸ " : ""
            // Le nom est raccourci : la barre de menus est étroite, et le
            // compte à rebours est ce qu'on vient y lire.
            let title = controller?.title(of: taskPageID) ?? "Tâche"
            return "\(marker)\(time) · \(MenuBarLabel.short(title))"
        case .onBreak(let remaining, _):
            return "☕︎ \(SessionControls.format(remaining))"
        // Session finie ou repos : l'icône seule, jamais un décompte figé.
        case .breakSuggested, .idle, nil:
            return nil
        }
    }

    private var accessibilityLabel: String {
        guard let trailing else { return "Notitime" }
        return "Notitime — \(trailing)"
    }

    static func short(_ title: String, limit: Int = 18) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }
}
