import SwiftUI
import AppKit
import NotitimeCore

/// US4, US6 — l'écran qui suit un arrêt, avant de revenir à la liste.
///
/// Arrêter une session, c'est produire une entrée : le menu revenait pourtant
/// aussitôt à la liste des tâches, et rien ne disait ce qu'était devenue cette
/// entrée. Un seul sujet ici — la durée travaillée, au centre — et deux suites
/// possibles. L'écran s'efface au premier Échap ou à la fermeture du panneau,
/// sans effet de bord : l'entrée suit son cours dans la file.
struct CompletionView: View {

    @ObservedObject var controller: SessionController
    let completion: SessionController.SessionCompletion
    /// Ce que fait « J'ai terminé ma tâche » : le conteneur en profite pour
    /// replier le panneau de méthode, sans quoi la liste ne reviendrait pas.
    let finish: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 8)

            // Le sujet de l'écran : ce qui a été travaillé. L'état d'envoi le
            // surmonte en petit — il renseigne, il ne se lit pas en premier.
            VStack(spacing: 2) {
                delivery
                    // Une identité par état : sans elle, SwiftUI remplacerait le
                    // texte sur place et aucune transition ne se jouerait.
                    .id(completion.delivery.id)
                    .transition(reduceMotion ? .identity : .blurOutUp)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25),
                               value: completion.delivery)

                Text("\(completion.minutes) min")
                    .font(Typography.display)
                    .foregroundStyle(Color.primary)
                    .contentTransition(.numericText())

                Text(verbatim: completion.taskTitle)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 8)

            actions
        }
        .frame(maxWidth: .infinity)
        // Échap referme, comme partout ailleurs dans le panneau.
        .onExitCommand { controller.dismissCompletion() }
        // Le panneau de la barre de menus se ferme en perdant le premier plan :
        // c'est le signal qu'on l'a quitté, et l'écran s'en va avec lui — sauf
        // si l'on vient de partir consulter l'entrée dans Notion.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            controller.panelDidClose()
        }
    }

    /// Ce qui vient de se passer, dit en une ligne discrète et refermée par un
    /// trait : c'est un en-tête, pas le sujet.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typography.compact)
                .foregroundStyle(.secondary)
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Un suivi libre s'arrête quand on l'a décidé ; un pomodoro arrêté avant
    /// l'heure n'a rien d'une réussite. Aucun des deux ne se félicite.
    private var title: LocalizedStringKey {
        completion.mode == .pomodoro ? "Pomodoro arrêté" : "Session terminée"
    }

    // MARK: - Où en est l'entrée (FR-026, FR-030)

    @ViewBuilder
    private var delivery: some View {
        switch completion.delivery {
        case .sending:
            line(Text("On l'envoie dans Notion…"))

        case .sent(let url):
            if let url {
                Button {
                    // On part voir l'entrée : l'écran attend le retour.
                    controller.holdCompletion()
                    openURL(url)
                } label: {
                    line(Text("Enregistré dans Notion"), symbol: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .help("Ouvrir l'entrée dans Notion")
            } else {
                line(Text("Enregistré dans Notion"), symbol: "checkmark.circle")
            }

        case .pending:
            // Le détail — cause et action — reste porté par l'indicateur de
            // file, qui n'est pas propre à cet écran (FR-030).
            line(Text("En attente d'envoi"))
        }
    }

    /// Le texte, et le symbole à sa droite. Le symbole hérite de la police du
    /// texte : il grandit et rapetisse avec lui, sans être réglé à part.
    private func line(_ text: Text, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            text
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
        }
        .font(Typography.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }

    // MARK: - Les deux suites

    private var actions: some View {
        HStack(spacing: 8) {
            Button { Task { await controller.relaunch() } } label: {
                Text("Relancer").controlLabel()
            }
            .buttonStyle(.borderedProminent)
            // Entrée relance : c'est la suite la plus fréquente.
            .keyboardShortcut(.defaultAction)

            // La tâche passe à « terminé » dans Notion, et la liste revient.
            Button(action: finish) {
                Text("J'ai terminé ma tâche").controlLabel()
            }
        }
        .frame(maxWidth: .infinity)
    }
}
