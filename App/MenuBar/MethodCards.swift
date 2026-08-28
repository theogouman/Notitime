import SwiftUI
import NotitimeCore

/// Choix de la méthode, une fois la tâche choisie (FR-016, FR-018).
///
/// Deux cartes côte à côte plutôt qu'une liste de boutons : le choix se fait
/// d'abord entre deux façons de travailler, la durée ne venant qu'ensuite. Les
/// durées de Pomodoro se découvrent au survol de sa carte, qui passe alors au
/// second plan — c'est la même surface qui porte les deux étapes, sans que le
/// panneau ne change de taille ni que rien ne se déplace sous le curseur.
struct MethodCards: View {

    @ObservedObject var controller: SessionController

    @State private var hovered: SessionMode?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comment veux-tu travailler ?")
                .font(.callout.weight(.semibold))

            HStack(spacing: 10) {
                pomodoro
                tracker
            }
            .frame(height: height)
        }
    }

    // MARK: - Pomodoro

    private var pomodoro: some View {
        ZStack {
            face(icon: "timer", title: "Pomodoro")
                // Le fond s'efface sans disparaître : la carte reste
                // reconnaissable pendant qu'on choisit sa durée.
                .blur(radius: revealsDurations ? 5 : 0)
                .opacity(revealsDurations ? 0.25 : 1)

            durations
                .opacity(revealsDurations ? 1 : 0)
                // Toujours présentes, mais inertes tant qu'elles sont invisibles :
                // c'est ce qui garde le raccourci Entrée disponible sur la
                // dernière durée employée, que la souris survole ou non.
                .allowsHitTesting(revealsDurations)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface(isPromoted: promotes(.pomodoro)))
        .contentShape(Rectangle())
        .onHover { inside in transition { hovered = inside ? .pomodoro : nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pomodoro")
    }

    private var revealsDurations: Bool { hovered == .pomodoro }

    private var durations: some View {
        VStack(spacing: 4) {
            ForEach(controller.pomodoroPresets, id: \.self) { minutes in
                Button("\(minutes) min") {
                    Task { await controller.startPomodoro(minutes: minutes) }
                }
                .buttonStyle(DurationButtonStyle(isPromoted: promotes(.pomodoro, minutes)))
                .keyboardShortcut(promotes(.pomodoro, minutes) ? .defaultAction : nil)
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Suivi libre

    private var tracker: some View {
        Button { Task { await controller.startTracker() } } label: {
            face(icon: "clock", title: "Suivi libre")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(surface(isPromoted: promotes(.tracker), isHovered: hovered == .tracker))
        .onHover { inside in transition { hovered = inside ? .tracker : nil } }
        .keyboardShortcut(promotes(.tracker) ? .defaultAction : nil)
    }

    // MARK: - Pièces communes

    private func face(icon: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
        }
    }

    /// Fond de carte. Le liseré d'accent marque la dernière méthode employée,
    /// celle que la touche Entrée lance.
    private func surface(isPromoted: Bool, isHovered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.10 : 0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isPromoted ? Color.accentColor.opacity(0.7) : .clear,
                                  lineWidth: 1.5)
            }
    }

    /// La dernière méthode lancée est mise en avant. À défaut d'historique,
    /// c'est le premier préréglage de Pomodoro qui l'emporte.
    private func promotes(_ mode: SessionMode, _ minutes: Int? = nil) -> Bool {
        guard let last = controller.lastMethod else {
            guard mode == .pomodoro else { return false }
            return minutes == nil || minutes == controller.pomodoroPresets.first
        }
        guard last.mode == mode else { return false }
        return mode == .tracker || minutes == nil || last.minutes == minutes
    }

    private func transition(_ change: @escaping () -> Void) {
        guard !reduceMotion else { return change() }
        withAnimation(.easeOut(duration: 0.18)) { change() }
    }
}

/// Une durée de Pomodoro : ligne pleine largeur, mise en avant si c'est la
/// dernière employée.
struct DurationButtonStyle: ButtonStyle {
    let isPromoted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill(configuration.isPressed))
            )
            .foregroundStyle(isPromoted ? Color.white : Color.primary)
            .contentShape(Rectangle())
    }

    private func fill(_ pressed: Bool) -> Color {
        if isPromoted { return Color.accentColor.opacity(pressed ? 0.7 : 1) }
        return Color.primary.opacity(pressed ? 0.20 : 0.10)
    }
}
