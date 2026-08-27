import SwiftUI
import SwiftData
import AppKit
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
            // Au repos, uniquement l'icône. Le compte à rebours et le chronomètre
            // viendront s'y afficher avec la machine à états (FR-025).
            Image(systemName: "timer")
        }
        .menuBarExtraStyle(.window)
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

    init() {
        do {
            let environment = try AppEnvironment()
            self.environment = environment
            self.onboarding = OnboardingModel(environment: environment)
            Task { await validateAtStartup(environment) }
        } catch {
            startupMessage = error.localizedDescription
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

struct RootView: View {
    @ObservedObject var state: RootState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = state.startupMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }

            if let onboarding = state.onboarding {
                OnboardingView(model: onboarding)
            } else {
                Text("Notitime n'a pas pu démarrer.").font(.callout)
            }

            Divider()
            Button("Quitter") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }
}
