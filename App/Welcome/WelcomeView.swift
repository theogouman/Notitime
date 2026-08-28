import SwiftUI
import NotitimeCore

/// L'accueil du premier lancement, du récit au premier chronomètre.
struct WelcomeView: View {

    @ObservedObject var state: RootState
    @StateObject private var flow = WelcomeFlow()

    var body: some View {
        ZStack {
            background
            content
                .padding(.horizontal, 56)
                .padding(.vertical, 40)
        }
        .frame(minWidth: WelcomeWindow.size.width, minHeight: WelcomeWindow.size.height)
    }

    @ViewBuilder
    private var content: some View {
        if let model = state.onboarding {
            Group {
                switch flow.panel {
                case .manifesto:
                    ManifestoPanel { advance(.template) }
                case .template:
                    TemplatePanel { advance(.connect) }
                case .connect:
                    ConnectPanel(model: model)
                case .ready:
                    ReadyPanel(model: model) { finish() }
                }
            }
            // Chaque écran a son identité : sans elle, SwiftUI réutiliserait la
            // vue en place et rien ne se croiserait.
            .id(flow.panel)
            .transition(.page(forward: flow.forward))
            .onChange(of: model.isConnected) { _, connected in
                // La connexion aboutie fait avancer d'elle-même : l'utilisateur
                // revient du navigateur, l'écran suivant l'attend.
                guard connected, flow.panel == .connect else { return }
                advance(.ready)
            }
        } else {
            Text("Notitime n'a pas pu démarrer.").font(.callout)
        }
    }

    /// Un fond qui bouge à peine, pour que la fenêtre ne soit pas une page
    /// blanche — et qui reste derrière le texte, jamais devant.
    private var background: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    private func advance(_ panel: WelcomeFlow.Panel) {
        withAnimation(Motion.ease(Motion.pageDuration)) { flow.advance(to: panel) }
    }

    /// Fin de l'accueil : il ne se rouvrira pas, la fenêtre se ferme, et le menu
    /// s'ouvre sur les tâches déjà chargées.
    private func finish() {
        state.completeWelcome()
        WelcomeWindow.close()
        StatusItemOpener.open()
    }
}
