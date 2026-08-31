import SwiftUI
import AppKit

/// Une durée qu'on ajuste sans quitter la ligne où on la lit.
///
/// Un `Stepper` sépare la valeur de ses flèches et fige la première : pour
/// passer de 5 à 45 minutes, il fallait quarante clics ou rien. Ici la pastille
/// **est** le contrôle — les flèches paraissent au survol, et le nombre se
/// clique pour être écrit à la main. Rien ne s'affiche tant qu'on ne s'approche
/// pas : au repos, la ligne ne montre que des durées.
struct DurationPill: View {

    @Binding var minutes: Int
    /// Bornes de saisie : une session de zéro minute finirait avant de commencer.
    var range: ClosedRange<Int> = 1...180
    /// L'unité, écrite après le nombre. Vide quand la question l'a déjà dit.
    var unit: String = ""
    /// La pastille est celle qui sert de repère — la durée par défaut.
    var isLeading = false

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    /// Place de la pastille dans la fenêtre, pour savoir si un clic la vise.
    @State private var bounds: CGRect = .zero
    /// L'observateur de clics posé le temps de la saisie.
    @State private var clicks: Any?
    @FocusState private var focused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        value
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            // Les flèches se posent **par-dessus** la marge droite : réservée
            // dans le rang, leur place décentrait le nombre en permanence ; non
            // réservée, elle poussait les pastilles voisines au survol.
            .overlay(alignment: .trailing) {
                arrows
                    .padding(.trailing, 3)
                    .opacity(hovering && !editing ? 1 : 0)
            }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering || editing ? 0.12 : 0.075))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(editing ? 0.9 : 0), lineWidth: 1)
        }
        // Le fond et le liseré changent, jamais la taille : la pastille gardait
        // sa largeur de lecture puis prenait celle du champ, et sautait sous le
        // curseur au moment précis où on venait écrire dedans.
        .animation(reduceMotion ? nil : Motion.ease(0.15), value: hovering)
        .animation(reduceMotion ? nil : Motion.ease(0.15), value: editing)
        .onHover { inside in hovering = inside }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { bounds = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, now in bounds = now }
            }
        )
        .onDisappear { endEditing(keeping: false) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(minutes) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(+1)
            case .decrement: step(-1)
            default: break
            }
        }
    }

    // MARK: - Le nombre

    @ViewBuilder
    private var value: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Typography.control)
                .multilineTextAlignment(.center)
                .focusEffectDisabled()
                .focused($focused)
                .frame(width: valueWidth, height: DurationPill.valueHeight)
                .onSubmit { endEditing(keeping: true) }
                // Le focus perdu vaut validation : cliquer ailleurs après avoir
                // écrit une durée veut dire qu'on la garde.
                .onChange(of: focused) { _, now in if !now { endEditing(keeping: true) } }
                .onExitCommand { endEditing(keeping: false) }
        } else {
            Button { startEditing() } label: {
                Text(unit.isEmpty ? "\(minutes)" : "\(minutes) \(unit)")
                    .font(Typography.control)
                    .foregroundStyle(isLeading ? Color.primary : .secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // Mêmes largeur **et** hauteur qu'en saisie : un champ de
                    // texte est plus haut qu'un texte à police égale, et la
                    // pastille grandissait au moment précis où l'on venait
                    // écrire dedans.
                    .frame(width: valueWidth, height: DurationPill.valueHeight)
            }
            .buttonStyle(.plain)
            .help("Cliquer pour écrire la durée")
        }
    }

    /// Deux demi-flèches : la molette d'un `Stepper`, à la taille d'une pastille.
    private var arrows: some View {
        VStack(spacing: 0) {
            arrow("chevron.up", by: +1)
            arrow("chevron.down", by: -1)
        }
    }

    private func arrow(_ symbol: String, by delta: Int) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10, height: 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!range.contains(minutes + delta))
    }

    // MARK: - Changer la valeur

    private func step(_ delta: Int) {
        let wanted = minutes + delta
        guard range.contains(wanted) else { return }
        withAnimation(reduceMotion ? nil : Motion.ease(0.2)) { minutes = wanted }
    }

    /// Largeur du nombre, la même en lecture et en saisie. Trois chiffres et,
    /// s'il y a lieu, l'unité : au-delà, la borne haute s'en charge.
    private var valueWidth: CGFloat { unit.isEmpty ? 30 : 52 }

    /// Hauteur du nombre, la même en lecture et en saisie.
    private static let valueHeight: CGFloat = 18

    private func startEditing() {
        draft = "\(minutes)"
        editing = true
        // Demandé avant que le champ n'existe, le focus se perd.
        DispatchQueue.main.async { focused = true }
        watchClicksOutside()
    }

    /// Un clic ailleurs referme la saisie.
    ///
    /// Le focus ne suffit pas : cliquer sur le fond d'une fenêtre — une zone
    /// inerte, sans contrôle à qui le donner — ne le retire à personne, et le
    /// champ restait ouvert derrière l'utilisateur parti faire autre chose.
    private func watchClicksOutside() {
        guard clicks == nil else { return }
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard editing, !hits(event) else { return event }
            endEditing(keeping: true)
            return event
        }
    }

    /// Le clic vise-t-il la pastille elle-même ?
    ///
    /// Deux repères opposés : AppKit compte depuis le bas de la fenêtre, SwiftUI
    /// depuis le haut de sa vue racine.
    private func hits(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        let point = CGPoint(x: event.locationInWindow.x,
                            y: content.bounds.height - event.locationInWindow.y)
        return bounds.contains(point)
    }

    private func endEditing(keeping: Bool) {
        if keeping, let written = Int(draft.filter(\.isNumber)), range.contains(written) {
            minutes = written
        }
        editing = false
        focused = false
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
    }
}
