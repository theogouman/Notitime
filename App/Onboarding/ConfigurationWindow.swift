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

    /// Ouvre la fenêtre et l'amène au premier plan.
    ///
    /// L'application est un agent (`LSUIElement`) : sans activation explicite, sa
    /// fenêtre s'ouvrirait derrière celle de l'application active.
    @MainActor
    static func present(_ openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ConfigurationView: View {
    @ObservedObject var state: RootState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, minHeight: 320)
    }
}
