import SwiftUI

/// Un champ de recherche, sans bezel ni anneau.
///
/// Le style `roundedBorder` d'AppKit apporte deux choses dont le panneau ne veut
/// pas : un liseré creusé, qui fait ressembler un menu à un formulaire, et un
/// halo bleu dès que le champ prend le focus — or celui du panneau l'a en
/// permanence, et celui d'un sélecteur l'a dès son ouverture. Le halo ne dit
/// donc jamais rien qu'on ne sache déjà, et il attire l'œil là où il n'y a rien
/// à lire. Ici, une plaque douce, une loupe, et rien d'autre.
struct SearchField: View {

    let placeholder: LocalizedStringKey
    @Binding var text: String
    /// Le focus, piloté de l'extérieur : `@FocusState` ne traverse pas une vue
    /// composée — posé sur `SearchField`, il ne désignerait aucun champ. La vue
    /// tient donc le sien et le tient synchronisé avec celui de l'appelant.
    var isFocused: Binding<Bool>?
    /// Hauteur : celle d'un contrôle du panneau. Les sélecteurs, plus étroits,
    /// se contentent d'un cran en dessous.
    var height: CGFloat = 26
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    private var wanted: Bool { isFocused?.wrappedValue ?? false }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focusEffectDisabled()
                .focused($focused)
                .onSubmit(onSubmit)
                // Demandé avant que SwiftUI n'ait posé le champ, le focus se
                // perd : on le prend au tour de boucle suivant.
                .onAppear { if wanted { DispatchQueue.main.async { focused = true } } }
                .onChange(of: focused) { _, now in
                    if isFocused?.wrappedValue != now { isFocused?.wrappedValue = now }
                }
                .onChange(of: wanted) { _, now in
                    if focused != now { focused = now }
                }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Effacer la recherche")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }
}

/// La plaque d'un menu flottant : le calendrier, la liste des projets.
///
/// Deux ombres plutôt qu'une — une courte qui pose la carte sur le fond, une
/// longue et diffuse qui la fait flotter. Une seule ombre large donne ce halo
/// gris qu'on voit sur les interfaces bâclées ; une seule ombre courte colle la
/// carte au fond.
struct FloatingCard: ViewModifier {

    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }
}

extension View {

    /// Pose la vue sur une plaque flottante.
    func floatingCard(radius: CGFloat = 12) -> some View {
        modifier(FloatingCard(radius: radius))
    }
}
