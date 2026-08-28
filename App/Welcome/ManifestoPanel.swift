import SwiftUI
import AppKit

/// Premier écran : pourquoi Notitime existe.
///
/// Le texte se dépose mot à mot, puis les deux promesses arrivent en pastilles,
/// puis le logo et l'appel à l'action. L'ordre est le sens de la lecture : rien
/// n'apparaît avant que ce qui le précède n'ait été lu.
struct ManifestoPanel: View {

    let start: () -> Void

    @State private var headRevealed = 0
    @State private var tailRevealed = 0
    @State private var showsPills = false
    @State private var showsFooter = false
    /// Un clic dépose tout : relire une animation qu'on a déjà vue est une
    /// perte de temps, et l'accueil peut se rouvrir.
    @State private var skipped = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StreamedLines(lines: ManifestoPanel.head, revealed: headRevealed)

            pills

            VStack(alignment: .leading, spacing: 16) {
                logo
                StreamedLines(lines: ManifestoPanel.tail, revealed: tailRevealed)
            }

            Staggered(index: 0, shown: showsFooter) {
                PrimaryCTA(title: "Démarrer", action: start)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { skipped = true }
        .task { await play() }
    }

    // MARK: - Les deux promesses

    private var pills: some View {
        HStack(spacing: 10) {
            ForEach(Array(ManifestoPanel.promises.enumerated()), id: \.offset) { rank, promise in
                Staggered(index: rank, shown: showsPills) {
                    HStack(spacing: 8) {
                        Image(systemName: ManifestoPanel.symbol(promise.symbol,
                                                                fallback: promise.fallback))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text(promise.label)
                            .font(.system(size: 15, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08)) }
                }
            }
        }
        // Les pastilles gardent leur place dès le départ : les faire pousser la
        // suite du texte au moment d'apparaître décalerait ce qu'on est en
        // train de lire.
        .frame(height: 40)
    }

    private var logo: some View {
        Staggered(index: 0, shown: showsFooter || tailRevealed > 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
        }
    }

    // MARK: - Déroulé

    private func play() async {
        guard !reduceMotion else { return revealEverything() }

        await stream(upTo: StreamedLines.count(ManifestoPanel.head)) { headRevealed = $0 }
        showsPills = true
        await pause(.milliseconds(520))
        await stream(upTo: StreamedLines.count(ManifestoPanel.tail)) { tailRevealed = $0 }
        showsFooter = true
    }

    private func revealEverything() {
        headRevealed = StreamedLines.count(ManifestoPanel.head)
        tailRevealed = StreamedLines.count(ManifestoPanel.tail)
        showsPills = true
        showsFooter = true
    }

    private func stream(upTo total: Int, _ apply: (Int) -> Void) async {
        for step in 1...max(1, total) {
            if skipped { return revealEverything() }
            apply(step)
            await pause(.milliseconds(Int(Motion.wordGap * 1000)))
        }
    }

    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    // MARK: - Le texte

    /// Le nom du symbole s'il existe sur ce système, un repli sinon : les
    /// symboles récents ne sont pas rendus par les versions antérieures, et une
    /// pastille sans icône vaut moins qu'une pastille avec une icône proche.
    static func symbol(_ name: String, fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }

    private struct Promise {
        let symbol: String
        let fallback: String
        let label: LocalizedStringKey
    }

    private static let promises = [
        Promise(symbol: "alarm", fallback: "alarm",
                label: "Là où tu passes trop de temps"),
        Promise(symbol: "eurosign.arrow.trianglehead.counterclockwise.rotate.90",
                fallback: "eurosign.arrow.circlepath",
                label: "Ta vraie rentabilité")
    ]

    /// Les phrases passent par le catalogue : le découpage en mots est une
    /// affaire de rendu, la traduction reste une affaire de phrases (FR-036).
    static let head: [StreamLine] = [
        StreamLine(id: 0, tokens: .words(String(localized: "Pendant des années")) + [.avatar]
                   + .words(String(localized: "j'ai construit"))),
        StreamLine(id: 1, tokens: .words(String(localized: "des systèmes sur Notion pour les TPE / PME."))),
        StreamLine(id: 2, tokens: .words(String(localized: "La gestion des tâches & projets revenait toujours"))),
        StreamLine(id: 3, tokens: []),
        StreamLine(id: 4, tokens: .words(String(localized: "Le problème ?"))),
        StreamLine(id: 5, tokens: .words(String(localized: "Suivre ses tâches, c'est bien."))),
        StreamLine(id: 6, tokens: .words(String(localized: "Savoir mesurer le temps qu'on y passe, c'est mieux.")),
                   weight: .semibold),
        StreamLine(id: 7, tokens: []),
        StreamLine(id: 8, tokens: .words(String(localized: "C'est ça qui permets d'identifier :")))
    ]

    static let tail: [StreamLine] = [
        StreamLine(id: 100, tokens: .words(String(localized: "Notitime t'aide à mesurer tout ça.")),
                   weight: .semibold, size: 24),
        StreamLine(id: 101, tokens: .words(String(localized: "Time Tracking intégré à Notion")) + [.notionLogo],
                   size: 17)
    ]
}
