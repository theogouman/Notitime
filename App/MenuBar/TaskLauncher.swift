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

    /// Hauteur du bloc, identique dépliée ou repliée.
    private let height: CGFloat = 240

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
        .frame(height: height, alignment: .top)
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

            // FR-018 — les préréglages de durée, plus la valeur personnalisée.
            VStack(alignment: .leading, spacing: 6) {
                Text("Pomodoro")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(controller.pomodoroPresets, id: \.self) { minutes in
                        Button("\(minutes) min") {
                            Task { await controller.startPomodoro(minutes: minutes) }
                        }
                        .buttonStyle(PromotedButtonStyle(isPromoted: isLast(.pomodoro, minutes)))
                        .keyboardShortcut(isLast(.pomodoro, minutes) ? .defaultAction : nil)
                    }
                }
            }

            // FR-016 — durée libre : une seule commande, aucune valeur à choisir.
            VStack(alignment: .leading, spacing: 6) {
                Text("Suivi libre")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button("Démarrer le suivi") {
                    Task { await controller.startTracker() }
                }
                .buttonStyle(PromotedButtonStyle(isPromoted: isLast(.tracker, nil)))
                .keyboardShortcut(isLast(.tracker, nil) ? .defaultAction : nil)
            }

            Spacer(minLength: 0)
        }
        // Le champ de recherche disparaît en gardant le focus : celui-ci passe
        // au premier élément focalisable du panneau — l'en-tête — qui héritait
        // alors de l'anneau bleu, à l'endroit même où était le champ.
        .focusEffectDisabled()
    }

    /// La dernière méthode lancée est mise en avant et déclenchée par Entrée.
    /// À défaut d'historique, c'est le premier préréglage qui l'emporte.
    private func isLast(_ mode: SessionMode, _ minutes: Int?) -> Bool {
        guard let last = controller.lastMethod else {
            return mode == .pomodoro && minutes == controller.pomodoroPresets.first
        }
        guard last.mode == mode else { return false }
        return mode == .tracker || last.minutes == minutes
    }

    // MARK: - Transitions

    private func expand(_ task: CachedTaskItem) {
        controller.selectedTaskID = task.id
        highlighted = task.id
        transition { expanded = task.id }
    }

    private func collapse() {
        guard expanded != nil else { return }
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

/// Bouton mis en avant, ou non, selon qu'il porte la dernière méthode utilisée.
///
/// `.borderedProminent` et `.bordered` sont deux types distincts : les choisir
/// dans une expression ternaire ne compile pas, d'où ce style qui tranche à
/// l'intérieur.
struct PromotedButtonStyle: PrimitiveButtonStyle {
    let isPromoted: Bool

    func makeBody(configuration: Configuration) -> some View {
        if isPromoted {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}
