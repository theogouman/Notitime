import SwiftUI

/// Une rangée qui passe à la ligne toute seule — des mots et des pastilles
/// mêlés dans la même phrase.
///
/// `Text` sait couper un texte, mais pas y intercaler des vues ; un `HStack`
/// sait intercaler des vues, mais pas couper. D'où ce `Layout` : chaque mot est
/// une vue, et les touches citées en sont une aussi.
struct FlowLayout: Layout {

    /// Espace entre deux mots — celui d'une espace typographique, pas celui
    /// d'une rangée de boutons.
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 7
    /// Lignes centrées : sous un titre centré, un bloc aligné à gauche pendrait
    /// d'un côté.
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = lines(subviews, width: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return CGSize(width: min(lines.map(\.width).max() ?? 0, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x: CGFloat
            switch alignment {
            case .leading: x = bounds.minX
            case .trailing: x = bounds.maxX - line.width
            default: x = bounds.minX + (bounds.width - line.width) / 2
            }
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                // Centrage vertical dans la ligne : une pastille est plus haute
                // qu'un mot, et deux hauteurs alignées par le haut se voient.
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, width maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = current.indices.isEmpty ? size.width
                                                   : current.width + spacing + size.width
            if !current.indices.isEmpty && extended > maxWidth {
                lines.append(current)
                current = Line(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

/// Un élément d'interface cité comme une touche : son icône, parfois son nom,
/// sur fond légèrement contrasté à bords arrondis.
///
/// Nommer un bouton entre guillemets oblige à le chercher ; le montrer tel
/// qu'il apparaît à l'écran le fait reconnaître d'un coup d'œil.
struct KeyCap: View {

    let symbol: String
    var label: LocalizedStringKey?
    /// Ponctuation collée à la touche, hors du fond : sans cela, un point après
    /// une pastille part seul à la ligne suivante.
    var suffix: String?

    /// Toutes les touches à la même hauteur, quelle que soit leur garniture.
    ///
    /// Une icône seule donnait une pastille plus courte que celle qui porte un
    /// nom : à fond égal, la plus petite paraissait plus claire — deux teintes
    /// là où il n'y en a qu'une.
    private static let height: CGFloat = 21

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(Typography.compact)
                if let label {
                    Text(label).font(Typography.compact)
                }
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 30)
            .frame(height: KeyCap.height)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.09))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            if let suffix {
                Text(verbatim: suffix)
            }
        }
    }
}

enum Sentence {

    /// Un fragment de phrase, découpé en mots pour que la rangée puisse le
    /// couper où il faut.
    ///
    /// Le découpage a lieu ici et non à l'écriture : la phrase reste une seule
    /// chaîne traduisible, et non une liste de mots. Une fonction, et non une
    /// vue : `FlowLayout` ne voit les mots un à un que si la `ForEach` lui
    /// arrive telle quelle.
    @ViewBuilder
    static func words(_ text: String.LocalizationValue) -> some View {
        let resolved = String(localized: text)
        ForEach(Array(resolved.split(separator: " ").enumerated()), id: \.offset) { _, word in
            Text(verbatim: String(word))
        }
    }
}
