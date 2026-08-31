import SwiftUI

/// La mise en page commune aux écrans de session : un en-tête, un compteur dans
/// sa pastille, une ligne d'appoint, et deux boutons.
///
/// Les deux écrans se suivent — le compteur, puis la confirmation — et la
/// fenêtre ne change pas de taille entre les deux. Tout ce qui bouge d'un écran
/// à l'autre se lit donc comme un défaut : un compteur qui perd son fond, des
/// boutons qui changent de hauteur, une ligne qui n'est plus au même endroit.
/// Une seule mise en page pour les deux, et les éléments restent en place.
struct SessionPanel<Counter: View, Note: View, Actions: View>: View {

    /// Le titre discret, refermé par un trait : c'est un en-tête, pas le sujet.
    let title: String
    /// Ce que le compteur mesure, dit au-dessus de lui. Rien quand le compteur
    /// se suffit : un cadran qui décompte n'a pas besoin qu'on annonce qu'il
    /// décompte.
    var caption: LocalizedStringKey? = nil
    /// Le compteur : une pastille, ou le cadran d'un pomodoro. Le seul chiffre
    /// de l'écran, quelle que soit sa forme.
    @ViewBuilder var counter: Counter
    /// La ligne sous le compteur — l'état d'envoi, la durée de pause. Sa place
    /// est réservée même vide : sans quoi les boutons remonteraient.
    @ViewBuilder var note: Note
    @ViewBuilder var actions: Actions

    /// Hauteur réservée à la ligne d'appoint, celle d'une légende.
    private static var noteHeight: CGFloat { 15 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(Typography.compact)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                if let caption {
                    Text(caption)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }

                counter

                // La place est tenue par un rectangle transparent, pas par le
                // cadre de la note : une vue vide ne prend aucune hauteur, et
                // l'écran sans note remontait de quinze points par rapport à
                // l'autre — les boutons ne tombaient plus au même endroit.
                ZStack {
                    Color.clear.frame(height: SessionPanel.noteHeight)
                    note
                }

                // Les boutons gardent leur largeur naturelle : serrés à celle de
                // la pastille, « Terminé » s'écrivait « Ter… ». Un libellé qu'on
                // ne peut pas lire ne dit plus ce que fait le bouton.
                actions
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Le compteur dans sa pastille.
///
/// Le fond le détache de tout le reste, et la pastille se serre sur lui —
/// étendue à la fenêtre, elle ne mettait plus rien en valeur, elle faisait une
/// barre grise.
struct CounterPill: View {

    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Typography.display)
            .foregroundStyle(Color.primary)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: false))
            .animation(.easeOut(duration: 0.25), value: text)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }
}
