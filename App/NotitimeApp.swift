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

        // Fenêtre à la demande : elle n'existe que si l'utilisateur l'ouvre, ce
        // que le principe I autorise — il ne proscrit qu'une fenêtre permanente.
        Window("Configuration de Notitime", id: ConfigurationWindow.id) {
            ConfigurationView(state: root)
                .modelContainer(root.containerOrEmpty)
        }
        .defaultSize(width: 480, height: 520)
        .windowResizability(.contentMinSize)
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
                session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            ]
            onboarding.restoreFromPersistence()
            Task {
                await validateAtStartup(environment)
                // Une session retrouvée reprend la main avant toute autre chose :
                // son état est déjà persisté, l'écran doit le refléter (FR-022).
                await session.restore()
                if onboarding.isConfigured { await session.loadTasks() }
            }
        } catch {
            startupMessage = error.localizedDescription
        }
    }

    /// Vrai quand Notitime a de quoi travailler : une connexion et les rôles
    /// indispensables liés.
    var isConfigured: Bool { onboarding?.isConfigured ?? false }

    var workspaceSummary: String {
        guard let onboarding, !onboarding.workspaceName.isEmpty else {
            return "Connecté à Notion."
        }
        return "Connecté à \(onboarding.workspaceName)."
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = state.startupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            summary

            if state.isConfigured, let session = state.session {
                SessionControls(controller: session)
                Divider()
            }

            if state.isConfigured {
                Button("Réglages…") { ConfigurationWindow.present(openWindow) }
            } else {
                Button("Configurer Notitime…") { ConfigurationWindow.present(openWindow) }
                    .buttonStyle(.borderedProminent)
            }

            Divider()
            Button("Quitter") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
    }

    @ViewBuilder
    private var summary: some View {
        if state.onboarding == nil {
            Text("Notitime n'a pas pu démarrer.").font(.callout)
        } else if state.isConfigured {
            Text(state.workspaceSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Notitime n'est pas encore relié à Notion.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}



/// Libellé de la barre de menus (FR-025).
struct MenuBarLabel: View {
    @ObservedObject var state: RootState

    var body: some View {
        switch state.session?.phase {
        case .running(let remaining, let taskPageID):
            // Le nom est raccourci : la barre de menus est étroite, et le
            // compte à rebours est ce qu'on vient y lire.
            let title = state.session?.title(of: taskPageID) ?? "Tâche"
            Text("\(SessionControls.format(remaining)) · \(MenuBarLabel.short(title))")
        case .onBreak(let remaining, _):
            Text("☕︎ \(SessionControls.format(remaining))")
        case .breakSuggested:
            // La session est finie : l'icône seule, pas un décompte figé.
            Image(systemName: "timer")
        default:
            Image(systemName: "timer")
        }
    }

    static func short(_ title: String, limit: Int = 18) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }
}
