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
    /// Durée survolée, pour la mettre en avant sous le curseur.
    @State private var hoveredDuration: Int?
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
        .background(surface())
        .contentShape(Rectangle())
        .onHover { inside in
            transition { hovered = inside ? .pomodoro : nil }
            if !inside { hoveredDuration = nil }
        }
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
                .buttonStyle(DurationButtonStyle(isHighlighted: hoveredDuration == minutes))
                .onHover { inside in hoveredDuration = inside ? minutes : nil }
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Suivi libre

    private var tracker: some View {
        Button { Task { await controller.startTracker() } } label: {
            face(icon: "alarm", title: "Suivi libre")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(surface(isHovered: hovered == .tracker))
        .onHover { inside in transition { hovered = inside ? .tracker : nil } }
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

    /// Fond de carte.
    ///
    /// Aucune méthode n'est mise en avant à l'ouverture du panneau : la
    /// précédente y restait sélectionnée, ce qui donnait un choix déjà fait
    /// alors qu'on vient précisément le faire. Seul le survol distingue.
    private func surface(isHovered: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(isHovered ? 0.10 : 0.06))
    }

    private func transition(_ change: @escaping () -> Void) {
        guard !reduceMotion else { return change() }
        withAnimation(.easeOut(duration: 0.18)) { change() }
    }
}

/// Une durée de Pomodoro : ligne pleine largeur, prise par la couleur d'accent
/// sous le curseur — celle que l'utilisateur a choisie dans ses réglages système.
struct DurationButtonStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill(configuration.isPressed))
            )
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .contentShape(Rectangle())
    }

    private func fill(_ pressed: Bool) -> Color {
        guard isHighlighted else { return Color.primary.opacity(pressed ? 0.20 : 0.10) }
        return Color.accentColor.opacity(pressed ? 0.7 : 1)
    }
}
