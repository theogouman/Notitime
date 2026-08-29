import SwiftUI
import NotitimeCore

/// Choix de la tâche, puis de la méthode, sans changer d'écran (SC-002).
///
/// La liste et le panneau de lancement occupent le même espace : déplier une
/// tâche replie la recherche et les autres lignes, et le panneau prend la place
/// libérée. La hauteur du conteneur est fixe pour que le cadre du popover ne
/// saute pas d'un état à l'autre — SwiftUI recalculerait sinon la taille de la
/// fenêtre pendant l'animation.
struct TaskLauncher: View {

    @ObservedObject var controller: SessionController
    /// Tâche dépliée, pilotée depuis l'extérieur : « Repartir » après une pause
    /// doit pouvoir ouvrir directement le panneau sur la tâche courante.
    @Binding var expanded: String?

    @State private var query = ""
    @State private var highlighted: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hauteur plancher du bloc, dépliée ou repliée.
    ///
    /// Le bloc prend tout ce que le panneau lui laisse, et pas un point de plus :
    /// une hauteur imposée dépassait le panneau dès qu'un avis s'ajoutait
    /// au-dessus, et c'est le bas du panneau — le bouton des options — qui en
    /// faisait les frais. Ce plancher garde la liste lisible si l'espace vient
    /// à manquer ; le trop-plein est rogné, jamais poussé dehors.
    private let minimumHeight: CGFloat = 140

    var body: some View {
        Group {
            if let task = expandedTask {
                panel(task)
            } else {
                TaskList(controller: controller, query: $query, highlighted: $highlighted) { task in
                    expand(task)
                }
            }
        }
        .frame(minHeight: minimumHeight, maxHeight: .infinity, alignment: .top)
        .onMoveCommand { move($0) }
        .onExitCommand { collapse() }
    }

    private var expandedTask: CachedTaskItem? {
        controller.tasks.first { $0.id == expanded }
    }

    // MARK: - Panneau de lancement

    @ViewBuilder
    private func panel(_ task: CachedTaskItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: collapse) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let project = controller.projectName(of: task) {
                            Text(project)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Revenir à la liste des tâches")

            Divider()

            MethodCards(controller: controller)

            Spacer(minLength: 0)
        }
        // Le champ de recherche disparaît en gardant le focus : celui-ci passe
        // au premier élément focalisable du panneau — l'en-tête — qui héritait
        // alors de l'anneau bleu, à l'endroit même où était le champ.
        .focusEffectDisabled()
    }

    // MARK: - Transitions

    private func expand(_ task: CachedTaskItem) {
        controller.selectedTaskID = task.id
        transition { expanded = task.id }
    }

    /// La désignation est oubliée en repliant : elle appartient au parcours au
    /// clavier en cours, pas à la liste. Conservée, elle rouvrait la liste avec
    /// une ligne teintée que personne n'avait désignée.
    private func collapse() {
        guard expanded != nil else { return }
        highlighted = nil
        transition { expanded = nil }
    }

    /// La recherche est conservée au retour : la liste se redéploie telle
    /// qu'elle était, ce qui est le sens même d'un aller-retour.
    private func transition(_ change: @escaping () -> Void) {
        guard !reduceMotion else { return change() }
        withAnimation(.easeOut(duration: 0.25)) { change() }
    }

    // MARK: - Clavier

    private func move(_ direction: MoveCommandDirection) {
        guard expanded == nil, !controller.tasks.isEmpty else { return }
        let ids = controller.tasks.map(\.id)
        let current = highlighted.flatMap { ids.firstIndex(of: $0) }

        switch direction {
        case .down:
            highlighted = ids[min((current ?? -1) + 1, ids.count - 1)]
        case .up:
            highlighted = ids[max((current ?? 0) - 1, 0)]
        default:
            break
        }
    }
}
