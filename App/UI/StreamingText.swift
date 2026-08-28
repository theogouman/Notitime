import SwiftUI
import AppKit

/// Un élément du flux : un mot, ou une image incrustée dans la phrase.
enum StreamToken {
    case word(String)
    case avatar
    case notionLogo
    case appLogo
}

/// Une ligne du flux, avec l'emphase à lui donner.
struct StreamLine: Identifiable {
    let id: Int
    let tokens: [StreamToken]
    var weight: Font.Weight = .regular
    var size: CGFloat = 20
    /// Ligne vide : elle ne consomme aucun mot et sert d'espace.
    var isBlank: Bool { tokens.isEmpty }
}

/// Texte qui se dépose mot à mot.
///
/// Transposition de « streaming text » : chaque mot part invisible et flou, puis
/// se pose, un toutes les `wordGap`. La recette insiste sur la différence avec
/// une machine à écrire — le flou qui se lève donne une impression de mots qui
/// se condensent, pas de touches frappées une à une.
///
/// Les mots sont posés individuellement plutôt qu'en un seul `Text` : c'est la
/// seule façon d'animer chacun séparément, et cela permet d'incruster l'avatar
/// au milieu d'une phrase.
struct StreamedLines: View {

    let lines: [StreamLine]
    /// Nombre de mots déjà déposés.
    let revealed: Int
    /// Ligne qui scintille — celle sur laquelle le récit marque un temps.
    var shimmering: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { line in
                if line.isBlank {
                    Color.clear.frame(height: 10)
                } else {
                    // L'écart entre les mots suit la taille du texte : un
                    // espacement fixe paraît juste à 24 pt et bâillant à 17.
                    HStack(alignment: .firstTextBaseline, spacing: line.size * 0.26) {
                        ForEach(Array(line.tokens.enumerated()), id: \.offset) { position, token in
                            view(token, line: line)
                                .modifier(Word(isIn: isIn(line, position), reduce: reduceMotion))
                        }
                    }
                }
            }
        }
    }

    /// Une ligne, et son scintillement le cas échéant.
    ///
    /// La bande de surbrillance est découpée sur la ligne entière, pas sur
    /// chaque mot : découpée mot à mot, elle repartirait à zéro à chaque
    /// espace et le balayage ne se lirait plus.
    @ViewBuilder
    private func row(_ line: StreamLine) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: line.size * 0.26) {
            ForEach(Array(line.tokens.enumerated()), id: \.offset) { position, token in
                view(token, line: line)
                    .modifier(Word(isIn: isIn(line, position), reduce: reduceMotion))
            }
        }
        content.overlay {
            if shimmering == line.id, !reduceMotion {
                ShimmerSweep().mask(content).allowsHitTesting(false)
            }
        }
    }

    /// Index global du mot, toutes lignes confondues : c'est lui qui décide de
    /// l'ordre de dépôt.
    private func index(_ line: StreamLine, _ position: Int) -> Int {
        lines.prefix(while: { $0.id != line.id })
            .reduce(0) { $0 + $1.tokens.count } + position
    }

    private func isIn(_ line: StreamLine, _ position: Int) -> Bool {
        revealed > index(line, position)
    }

    @ViewBuilder
    private func view(_ token: StreamToken, line: StreamLine) -> some View {
        switch token {
        case .word(let word):
            Text(verbatim: word)
                .font(.system(size: line.size, weight: line.weight))
        case .avatar:
            // Le portrait respire dans son cercle : cadré au bord, il se
            // touchait les côtés et paraissait rogné.
            Image("Avatar")
                .resizable()
                .scaledToFit()
                .padding(line.size * 0.17)
                .frame(width: line.size * 1.35, height: line.size * 1.35)
                .background(Circle().fill(Color.white))
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.08)) }
                // Une image n'a pas de ligne de base : on l'aligne sur celle du
                // texte pour qu'elle se pose dans la phrase, pas à côté.
                .alignmentGuide(.firstTextBaseline) { $0.height * 0.82 }
        case .appLogo:
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: line.size, height: line.size)
                .alignmentGuide(.firstTextBaseline) { $0.height * 0.84 }
        case .notionLogo:
            Image("NotionLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: line.size, height: line.size)
                .alignmentGuide(.firstTextBaseline) { $0.height * 0.86 }
        }
    }

    /// Total de mots, pour savoir quand le flux est fini.
    static func count(_ lines: [StreamLine]) -> Int {
        lines.reduce(0) { $0 + $1.tokens.count }
    }

    /// Index du premier mot d'une ligne donnée.
    static func start(of id: Int, in lines: [StreamLine]) -> Int {
        lines.prefix(while: { $0.id != id }).reduce(0) { $0 + $1.tokens.count }
    }
}

/// L'état d'un mot : posé, ou pas encore.
private struct Word: ViewModifier {
    let isIn: Bool
    let reduce: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isIn || reduce ? 1 : 0)
            .blur(radius: isIn || reduce ? 0 : Motion.wordBlur)
            .animation(reduce ? nil : Motion.ease(Motion.wordFade), value: isIn)
    }
}

/// Découpe une phrase en mots.
extension Array where Element == StreamToken {
    static func words(_ sentence: String) -> [StreamToken] {
        sentence.split(separator: " ").map { .word(String($0)) }
    }
}
