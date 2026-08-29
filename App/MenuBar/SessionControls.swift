import SwiftUI
import NotitimeCore

/// T057, T059 — contrôles de session du menu.
struct SessionControls: View {

    @ObservedObject var controller: SessionController

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
                } else if let completion = controller.completion {
                    // US4, US6 — l'entrée vient d'être produite : on dit ce
                    // qu'elle devient avant de rendre la liste.
                    CompletionView(controller: controller, completion: completion) {
                        controller.expandedTaskID = nil
                        Task { await controller.finishTask() }
                    }
                } else {
                    TaskLauncher(controller: controller,
                                 expanded: $controller.expandedTaskID)
                }

            case .running(let remaining, let taskPageID):
                // Un Pomodoro a une échéance : le cadran la montre. Un suivi
                // libre n'en a pas — un anneau y serait une promesse fausse, et
                // c'est le temps écoulé qui devient le sujet de l'écran.
                if let remaining {
                    Text(controller.title(of: taskPageID)).font(.callout).lineLimit(1)
                    ring(remaining)
                    HStack(spacing: 6) {
                        // FR-018 : le Pomodoro n'offre pas de pause.
                        Button("Arrêter") { Task { await controller.stop() } }
                    }
                } else {
                    tracker(taskPageID)
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
        // Quitter l'écran de fin — par le bouton, par Échap ou en refermant le
        // panneau — doit ramener la liste des tâches. La tâche dépliée y
        // survivait, et le menu rouvrait sur le choix de la méthode.
        .onChange(of: controller.completion == nil) { _, gone in
            if gone { controller.expandedTaskID = nil }
        }
    }

    /// Le suivi libre en cours, bâti comme l'écran de fin : un en-tête discret,
    /// le chiffre au centre, et les suites en dessous, alignées sur lui.
    @ViewBuilder
    private func tracker(_ taskPageID: String) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.title(of: taskPageID))
                    .font(Typography.compact)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Divider()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Text("La session a commencé il y a…")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)

                // Le compteur dans sa pastille : c'est le seul chiffre de
                // l'écran, et le fond le détache de tout le reste. Elle se
                // serre sur lui — étendue à la fenêtre, elle ne mettait plus
                // rien en valeur, elle faisait juste une barre grise.
                Text(controller.elapsedLabel)
                    .font(Typography.display)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.easeOut(duration: 0.25), value: controller.elapsedLabel)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )

                // Sous le temps travaillé, en petit : depuis quand on s'est
                // arrêté. Le premier compte ce qui partira dans Notion, le
                // second ne compte que pour soi.
                if let paused = controller.pausedLabel {
                    Text("En pause depuis \(paused)")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: paused)
                }

                // Les deux suites, à la largeur de la pastille : l'alignement
                // fait le lien entre le chiffre et ce qu'on peut en faire.
                HStack(spacing: 8) {
                    Button { Task { await controller.togglePause() } } label: {
                        Text(controller.isPaused ? "Reprendre" : "Pause")
                            .controlLabel()
                            .frame(maxWidth: .infinity)
                    }
                    Button { Task { await controller.stop() } } label: {
                        HStack(spacing: 4) {
                            Text("Terminé")
                            Image(systemName: "checkmark.circle")
                        }
                        .controlLabel()
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                // La taille de contrôle standard des actions principales : les
                // boutons faisaient une ligne écrasée sous une pastille haute.
                .controlSize(.large)
                .padding(.top, 2)
            }
            // Le bloc se règle sur le plus large de ses éléments : la pastille
            // donne sa largeur aux boutons, et les trois s'alignent.
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
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
        controller.expandedTaskID = task
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
