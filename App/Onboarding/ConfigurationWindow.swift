import SwiftUI
import AppKit

/// Fenêtre de configuration : connexion Notion et désignation des bases.
///
/// Pourquoi une fenêtre et non le menu. Le popover d'un `MenuBarExtra` se ferme
/// au premier clic hors de lui et n'a pas de gestion du focus : un formulaire
/// en plusieurs étapes y est inutilisable — le bouton d'assignation refermait le
/// menu avant que l'utilisateur ne voie le résultat. Le plan sépare d'ailleurs
/// depuis l'origine les trois surfaces (`MenuBar/`, `Onboarding/`, `Settings/`),
/// et le principe I n'interdit qu'une fenêtre **permanente**.
///
/// Le menu reste dédié à l'usage quotidien : choisir une tâche, démarrer, arrêter.
enum ConfigurationWindow {

    static let id = "notitime.configuration"

    /// La fenêtre, si elle est ouverte.
    ///
    /// Sert d'ancre à la demande d'autorisation du navigateur : présentée sans
    /// ancre valable, macOS la place au petit bonheur — d'où une boîte flottant
    /// au-dessus de la fenêtre plutôt qu'attachée à elle.
    @MainActor
    static func window() -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && (window.identifier?.rawValue.contains(id) == true
                    || window.title == "Réglages de Notitime")
        }
    }

    @MainActor
    static func close() {
        window()?.close()
    }

    /// Ouvre la fenêtre et l'amène au premier plan.
    ///
    /// L'application est un agent (`LSUIElement`) : sans activation explicite, sa
    /// fenêtre s'ouvrirait derrière celle de l'application active.
    @MainActor
    static func present(_ openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Place l'application dans le Dock le temps des réglages.
    ///
    /// Notitime vit dans la barre des menus : sans icône dans le Dock, une
    /// fenêtre passée derrière une autre n'a plus de porte pour y revenir. Le
    /// statut suit la fenêtre — pris à son ouverture, rendu à sa fermeture — et
    /// non le lancement, sinon l'application occuperait le Dock en permanence.
    @MainActor
    static func showsInDock(_ shows: Bool) {
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
        // Reprendre le statut d'agent retire l'application du premier plan :
        // on la réactive pour que la fenêtre encore ouverte garde le focus.
        if shows { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct ConfigurationView: View {

    @ObservedObject var state: RootState

    /// Taille fixe de la fenêtre : les réglages ne gagnent rien à s'étirer, et
    /// une taille constante donne au sélecteur et aux feuilles une place stable.
    static let size = CGSize(width: 800, height: 600)

    private enum Tab: Hashable { case connection, settings }
    @State private var tab: Tab = .connection
    /// L'espace où la pilule voyage d'un onglet à l'autre.
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = state.startupMessage {
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            if let onboarding = state.onboarding {
                selector
                content(onboarding)
            } else {
                Text("Notitime n'a pas pu démarrer.").font(Typography.body)
            }
        }
        .padding(20)
        .frame(width: ConfigurationView.size.width, height: ConfigurationView.size.height,
               alignment: .topLeading)
        // Le statut suit la fenêtre plutôt que l'ouverture qui l'a demandée :
        // toutes les façons d'y arriver, restauration comprise, en héritent.
        .onAppear { ConfigurationWindow.showsInDock(true) }
        .onDisappear { ConfigurationWindow.showsInDock(false) }
    }

    /// Les deux onglets, dessinés plutôt que confiés à `TabView`.
    ///
    /// D'un onglet, AppKit ne retient que le texte et l'icône, dans cet ordre :
    /// le logo Notion ne pouvait pas suivre le mot. Le lui imposer par une
    /// image dessinée laissait un onglet vide — c'est ce qu'on voyait.
    ///
    /// Transposition de la recette « tabs sliding » de transitions.dev : une
    /// pilule glisse d'un onglet à l'autre au lieu d'apparaître sous le nouveau.
    /// En CSS, JavaScript écrit la position et la largeur de l'onglet actif sur
    /// la pilule, et la transition tween le reste ; ici, la pilule est une seule
    /// vue que `matchedGeometryEffect` déplace d'un onglet à l'autre, ce qui
    /// anime sa position **et** sa largeur — les deux propriétés de la recette,
    /// à la durée et à la courbe d'origine.
    private var selector: some View {
        HStack(spacing: 3) {
            segment(.connection) {
                Text("Connexion Notion")
                Image("NotionLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 14)
            }
            segment(.settings) {
                Text("Réglages")
                Image(systemName: "gear")
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func segment<Label: View>(_ value: Tab,
                                      @ViewBuilder label: () -> Label) -> some View {
        Button {
            // La pilule glisse ; sans mouvement demandé, elle saute.
            guard !reduceMotion else { return tab = value }
            withAnimation(Motion.ease(Motion.tabsDuration)) { tab = value }
        } label: {
            HStack(spacing: 6) { label() }
                .font(Typography.control)
                // La couleur suit la pilule à la même cadence : le nom actif
                // s'affirme pendant qu'elle arrive, au lieu de basculer avant.
                .foregroundStyle(tab == value ? Color.primary : Color.secondary)
                .frame(height: 24)
                .padding(.horizontal, 12)
                .background {
                    if tab == value {
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "pilule", in: pill)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(_ onboarding: OnboardingModel) -> some View {
        switch tab {
        case .connection:
            ScrollView {
                OnboardingView(model: onboarding)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .settings:
            // Se déconnecter depuis les réglages ramène à la connexion :
            // l'écran d'accueil y est déjà, et rester devant des réglages sans
            // connexion n'aurait aucun sens.
            SettingsView(state: state, onDisconnected: { tab = .connection })
        }
    }
}
