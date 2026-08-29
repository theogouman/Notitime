import SwiftUI
import AppKit

/// Le guide de partage d'une base : ce qu'il faut faire dans Notion pour que
/// Notitime puisse voir la base, montré plutôt que décrit.
///
/// Il prend la place de la liste des bases quand celle-ci ne contient pas ce
/// qu'on cherche : à ce moment précis, la question n'est plus « laquelle ? »
/// mais « pourquoi n'y est-elle pas ? ».
struct ConnectGuideView: View {

    /// Retour à la liste sans rien avoir fait.
    let onBack: () -> Void
    /// Retour à la liste, en cherchant à nouveau les bases accessibles.
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            video
            explanation
            // La rangée d'actions descend au bas de la page, à la même distance
            // du bord que « Fermer » sur la liste : les deux pages d'une même
            // feuille ne doivent pas faire sauter les boutons en se croisant.
            Spacer(minLength: 0)
            actions
        }
        .padding(16)
        .frame(width: DatabasePickerSheet.size.width, height: DatabasePickerSheet.size.height)
    }

    // MARK: - La démonstration

    @ViewBuilder
    private var video: some View {
        if let url = Bundle.main.url(forResource: "HowToConnect", withExtension: "mp4") {
            LoopingVideo(url: url)
                .aspectRatio(3 / 2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10))
                }
                .accessibilityLabel("Démonstration : partager une base avec Notitime")
        }
    }

    // MARK: - Le mode d'emploi

    private var explanation: some View {
        VStack(spacing: 10) {
            Text("Voilà comment connecter ta base de données")
                .font(Typography.title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Les deux commandes sont citées telles qu'elles apparaissent dans
            // Notion : on les reconnaît à l'écran au lieu de les chercher.
            FlowLayout(spacing: 4, lineSpacing: 7) {
                Sentence.words("Rends-toi dans la page dans laquelle se situe ta base de données, clique sur")
                KeyCap(symbol: "ellipsis")
                Sentence.words("puis la section")
                KeyCap(symbol: "rectangle.grid.2x2", label: "Connexion", suffix: ".")
                Sentence.words("Tu pourras ajouter Notitime pour qu'il puisse y accéder.")
            }
            // Une largeur un peu plus courte que le panneau : c'est ce qui donne
            // des lignes de longueur voisine plutôt qu'une dernière ligne seule.
            .frame(width: 380)
            .font(Typography.body)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ce qu'on fait ensuite

    private var actions: some View {
        HStack(spacing: 10) {
            // Revenir sans rien faire reste possible — au clavier aussi, sans
            // quoi la feuille n'aurait plus de sortie.
            Button { onBack() } label: {
                Text("Retour").controlLabel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: openNotion) {
                HStack(spacing: 6) {
                    Text("Ouvrir Notion")
                    Image(systemName: "arrow.up.forward")
                }
                .controlLabel()
            }

            Button(action: onDone) {
                HStack(spacing: 6) {
                    Text("C'est fait")
                    Image(systemName: "checkmark.circle")
                }
                .controlLabel()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// L'application de bureau si elle est installée, le site sinon : ouvrir le
    /// navigateur quand Notion est déjà là ferait recommencer la connexion.
    private func openNotion() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "notion.id") {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://app.notion.com/p/") {
            NSWorkspace.shared.open(url)
        }
    }
}
