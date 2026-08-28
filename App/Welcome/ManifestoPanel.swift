import SwiftUI
import AppKit

/// Premier écran : pourquoi Notitime existe.
///
/// Une mise en scène, pas un affichage. L'accueil se présente d'abord, se
/// retire, puis le récit se dépose mot à mot avec deux silences — après la
/// question, et après les deux promesses. Ces silences sont le propos : ils
/// laissent le temps de lire ce qui vient d'apparaître.
struct ManifestoPanel: View {

    let start: () -> Void

    @State private var heroShown = false
    @State private var heroGone = false
    @State private var headRevealed = 0
    @State private var tailRevealed = 0
    @State private var showsPills = false
    @State private var showsFooter = false
    /// Ligne qui scintille pendant un silence.
    @State private var shimmeringLine: Int?
    /// Un clic dépose tout : relire une animation déjà vue est une perte de
    /// temps, et elle se rejoue à la demande.
    @State private var skipped = false
    /// Change à chaque rejeu et relance la mise en scène.
    @State private var run = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// La cadence de la recette d'origine. Le hoquet qu'on lui reprochait ne
    /// venait pas d'elle : le second segment repartait du premier mot, et tout
    /// le texte déjà déposé se redéposait sous les yeux.
    private let wordGap = Duration.milliseconds(Int(Motion.wordGap * 1000))

    var body: some View {
        ZStack {
            hero
            story
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { skipped = true }
        .task(id: run) { await play() }
    }

    // MARK: - Accueil

    private var hero: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
            Text("Bienvenue dans Notitime")
                .font(.system(size: 42, weight: .medium))
        }
        .opacity(heroShown && !heroGone ? 1 : 0)
        // L'accueil s'en va vers le haut : le récit prend sa place par le bas,
        // et le regard suit le même sens que la lecture.
        .offset(y: heroGone ? -46 : (heroShown ? 0 : 18))
        .blur(radius: heroShown && !heroGone ? 0 : Motion.staggerBlur)
        .animation(reduceMotion ? nil : Motion.ease(0.6), value: heroShown)
        .animation(reduceMotion ? nil : Motion.ease(0.6), value: heroGone)
    }

    // MARK: - Récit

    private var story: some View {
        VStack(alignment: .leading, spacing: 20) {
            StreamedLines(lines: ManifestoPanel.head, revealed: headRevealed,
                          shimmering: shimmeringLine)
            pills
            StreamedLines(lines: ManifestoPanel.tail, revealed: tailRevealed)

            Staggered(index: 0, shown: showsFooter) {
                HStack(spacing: 16) {
                    PrimaryCTA(title: "Démarrer", action: start)
                    Button {
                        skipped = false
                        run += 1
                    } label: {
                        Label("Rejouer l'animation", systemImage: "arrow.clockwise")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.link)
                }
                .padding(.top, 8)
            }
        }
        .frame(width: 720, alignment: .leading)
        .opacity(heroGone ? 1 : 0)
        .animation(reduceMotion ? nil : Motion.ease(0.4), value: heroGone)
    }

    private var pills: some View {
        HStack(spacing: 10) {
            ForEach(Array(ManifestoPanel.promises.enumerated()), id: \.offset) { rank, promise in
                Staggered(index: rank, shown: showsPills) {
                    HStack(spacing: 8) {
                        Image(systemName: ManifestoPanel.symbol(promise.symbol,
                                                                fallback: promise.fallback))
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        Text(promise.label)
                            .font(.system(size: 17, weight: .medium))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08)) }
                }
            }
        }
        // Les pastilles gardent leur place dès le départ : les faire pousser la
        // suite du texte en apparaissant décalerait ce qu'on est en train de lire.
        .frame(height: 46)
    }

    // MARK: - Déroulé

    private func play() async {
        reset()
        guard !reduceMotion else { return revealEverything() }

        heroShown = true
        await pause(.milliseconds(2600))
        guard !Task.isCancelled else { return }
        heroGone = true
        await pause(.milliseconds(700))
        guard !Task.isCancelled else { return }

        // Silence après la question : c'est elle qui doit rester seule un
        // instant, sinon la réponse arrive avant qu'on ne l'ait posée. Elle
        // scintille pendant ce temps — le seul endroit de l'écran qui bouge.
        await stream(from: 0, upTo: ManifestoPanel.beat) { headRevealed = $0 }
        shimmeringLine = 4
        await pause(.milliseconds(1900))
        shimmeringLine = nil
        // Le second segment reprend là où le premier s'est arrêté.
        await stream(from: ManifestoPanel.beat,
                     upTo: StreamedLines.count(ManifestoPanel.head)) { headRevealed = $0 }

        guard !Task.isCancelled else { return }
        showsPills = true
        await pause(.milliseconds(1100))
        guard !Task.isCancelled else { return }

        await stream(from: 0, upTo: StreamedLines.count(ManifestoPanel.tail)) { tailRevealed = $0 }
        showsFooter = true
    }

    private func reset() {
        heroShown = false
        heroGone = false
        headRevealed = 0
        tailRevealed = 0
        showsPills = false
        showsFooter = false
    }

    private func revealEverything() {
        heroGone = true
        headRevealed = StreamedLines.count(ManifestoPanel.head)
        tailRevealed = StreamedLines.count(ManifestoPanel.tail)
        showsPills = true
        showsFooter = true
        shimmeringLine = nil
    }

    private func stream(from start: Int, upTo total: Int, _ apply: (Int) -> Void) async {
        guard total > start else { return }
        for step in (start + 1)...total {
            // Un rejeu annule la mise en scène précédente : sans cette sortie,
            // l'ancienne continuerait d'écrire par-dessus la nouvelle.
            if Task.isCancelled { return }
            if skipped { return revealEverything() }
            apply(step)
            await pause(wordGap)
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
                   + .words(String(localized: "j'ai construit")), size: 24),
        StreamLine(id: 1, tokens: .words(String(localized: "des systèmes sur Notion pour les TPE / PME.")), size: 24),
        StreamLine(id: 2, tokens: .words(String(localized: "La gestion des tâches & projets revenait toujours")), size: 24),
        StreamLine(id: 3, tokens: []),
        StreamLine(id: 4, tokens: .words(String(localized: "Le problème ?")), weight: .medium, size: 24),
        StreamLine(id: 5, tokens: .words(String(localized: "Organiser ses tâches, c'est bien.")), size: 24),
        StreamLine(id: 6, tokens: .words(String(localized: "Mesurer le temps qu'on y passe, c'est mieux.")),
                   weight: .semibold, size: 24),
        StreamLine(id: 7, tokens: []),
        StreamLine(id: 8, tokens: .words(String(localized: "C'est ça qui permets d'identifier :")), size: 24)
    ]

    /// Fin de la question : le silence se prend là.
    static let beat = StreamedLines.start(of: 5, in: ManifestoPanel.head)

    static let tail: [StreamLine] = [
        StreamLine(id: 100, tokens: [.word(String(localized: "Notitime")), .appLogo]
                   + .words(String(localized: "t'aide à mesurer tout ça.")),
                   weight: .medium, size: 30),
        StreamLine(id: 101, tokens: .words(String(localized: "Time Tracking intégré à Notion")) + [.notionLogo],
                   size: 19)
    ]
}
