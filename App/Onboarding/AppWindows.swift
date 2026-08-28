import SwiftUI
import AppKit

/// Les fenêtres auxquelles une boîte système peut s'ancrer.
///
/// L'accueil et la configuration sont deux fenêtres distinctes, et la connexion
/// Notion part de l'une ou de l'autre. La demande d'autorisation doit s'attacher
/// à celle qui est effectivement là — sans quoi macOS la pose n'importe où.
@MainActor
enum AppWindows {

    static func anchor() -> NSWindow? {
        WelcomeWindow.window() ?? ConfigurationWindow.window()
    }

    /// Attend qu'une fenêtre soit à l'écran, au plus une demi-seconde.
    ///
    /// Une connexion lancée depuis le menu ouvre la fenêtre puis enchaîne
    /// aussitôt : sans cette attente, l'autorisation cherche son ancre avant que
    /// la fenêtre n'existe.
    static func settle() async {
        for _ in 0..<20 where anchor() == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
