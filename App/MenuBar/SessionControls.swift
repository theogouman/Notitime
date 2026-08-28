import SwiftUI
import NotitimeCore

/// T057, T059 — contrôles de session du menu.
struct SessionControls: View {

    @ObservedObject var controller: SessionController
    /// Tâche dépliée dans le lanceur. Partagée avec le menu : reprendre après
    /// une pause rouvre le panneau sur la tâche courante plutôt que la liste.
    @State private var expandedTask: String?
    /// Tâche visée par une réassignation, indépendante du lanceur : le choix
    /// d'une cible de rattrapage n'est pas celui d'une prochaine session.
    @State private var reassignTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.phase {
            case .idle:
                if let pending = controller.idleArbitration {
                    // FR-024 — l'arbitrage passe avant toute nouvelle session.
                    idleArbitration(pending)
                } else {
                    TaskLauncher(controller: controller, expanded: $expandedTask)
                }

            case .running(let remaining, let taskPageID):
                Text(controller.title(of: taskPageID)).font(.callout).lineLimit(1)
                // Un Pomodoro a une échéance : le cadran la montre. Un suivi
                // libre n'en a pas — un anneau y serait une promesse fausse.
                if let remaining {
                    ring(remaining)
                } else {
                    countdown(controller.elapsedLabel, countsDown: false)
                }
                HStack(spacing: 6) {
                    // FR-018 : le Pomodoro n'offre pas de pause ; le Tracker si.
                    if controller.isTracker {
                        Button(controller.isPaused ? "Reprendre" : "Pause") {
                            Task { await controller.togglePause() }
                        }
                    }
                    Button("Arrêter") { Task { await controller.stop() } }
                }

            case .breakSuggested(let kind):
                // Rien ne tourne : on propose de commencer la pause, jamais de
                // l'arrêter — c'est ce bouton d'arrêt fantôme qui échouait.
                Text(kind.isLong ? "Pause longue proposée" : "Pause proposée")
                    .font(.callout)
                HStack(spacing: 6) {
                    Button("Prendre la pause") { Task { await controller.startBreak(kind) } }
                        .buttonStyle(.borderedProminent)
                    Button("Repartir") { Task { await resume() } }
                    Button("Plus tard") { Task { await controller.dismissBreak() } }
                }

            case .onBreak(let remaining, let isLong):
                Text(isLong ? "Pause longue" : "Pause").font(.callout)
                ring(remaining)
                HStack(spacing: 6) {
                    // US2.2 : on doit pouvoir repartir immédiatement.
                    Button("Repartir") { Task { await resume() } }
                    Button("Terminer la pause") { Task { await controller.stop() } }
                }
            }

            if let notice = controller.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // FR-030 — nombre d'entrées en attente, et détail des échecs.
            if controller.pendingCount > 0 {
                HStack(spacing: 6) {
                    Text("\(controller.pendingCount) entrée(s) en attente d'envoi.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Réessayer") { Task { await controller.drainOutbox() } }
                        .controlSize(.small)
                }
            }
            ForEach(controller.failedEntries, id: \.localID) { entry in
                failure(entry)
            }
        }
    }

    /// Le cadran d'une durée visée : temps restant au centre, part d'arc pour
    /// ce qu'il en reste.
    private func ring(_ remaining: Duration) -> some View {
        TimerRing(label: SessionControls.format(remaining),
                  progress: fraction(remaining),
                  endsAt: controller.endsAt)
    }

    /// Part restante. Sans cible connue l'anneau reste plein : mieux vaut un
    /// anneau qui n'informe pas qu'un anneau qui annonce l'échéance à tort.
    private func fraction(_ remaining: Duration) -> Double {
        guard let target = controller.targetSeconds, target > 0 else { return 1 }
        return min(1, max(0, remaining.seconds / Double(target)))
    }

    /// Le temps qui passe : chaque chiffre remplacé glisse vers le bas plutôt
    /// que de sauter, et seuls les chiffres qui changent bougent.
    /// Un Tracker compte à l'endroit : lui faire descendre ses chiffres
    /// contredirait ce qu'il montre.
    private func countdown(_ label: String, countsDown: Bool = true) -> some View {
        Text(label)
            .font(.system(.title2, design: .monospaced))
            .contentTransition(.numericText(countsDown: countsDown))
            .animation(.easeOut(duration: 0.25), value: label)
    }

    /// « Repartir » ramène au choix de la méthode sur la même tâche : la pause
    /// est close, et le panneau s'ouvre déplié plutôt que de repartir d'office
    /// sur une durée qu'on n'a pas choisie.
    private func resume() async {
        let task = controller.selectedTaskID
        if controller.phase.offersStop {
            await controller.stop()
        } else {
            await controller.dismissBreak()
        }
        expandedTask = task
    }

    /// FR-031 — réassigner une entrée en échec à une autre tâche avant renvoi.
    @ViewBuilder
    private func failure(_ entry: OutboxEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Échec : \(entry.title)").font(.caption).bold()
            Text(entry.failureCause ?? "cause inconnue")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if controller.tasks.isEmpty {
                Text("Aucune tâche en cache pour réassigner cette entrée.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Picker("", selection: $reassignTarget) {
                        Text("Choisir une tâche…").tag(String?.none)
                        ForEach(controller.tasks) { task in
                            Text(task.title).tag(Optional(task.id))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Button("Réassigner") {
                        guard let target = reassignTarget else { return }
                        Task { await controller.reassign(entry.localID, to: target) }
                    }
                    .controlSize(.small)
                    .disabled(reassignTarget == nil)
                }
            }
        }
    }

    /// FR-024 — conserver ou retrancher, avant toute mise en file.
    @ViewBuilder
    private func idleArbitration(_ session: CompletedSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inactivité détectée").font(.callout).bold()
            Text("\(EntryComposer.minutes(session.pendingIdleSeconds)) min sans activité "
                 + "pendant cette session de \(EntryComposer.minutes(session.effectiveSeconds)) min.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Retrancher") { Task { await controller.resolveIdle(subtract: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Conserver") { Task { await controller.resolveIdle(subtract: false) } }
            }
        }
    }

    /// `mm:ss`, ou `—` pour un Tracker qui n'a pas de cible.
    static func format(_ duration: Duration?) -> String {
        guard let duration else { return "—" }
        let total = max(0, Int(duration.seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
