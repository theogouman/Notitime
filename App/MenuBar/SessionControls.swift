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
            // Ce qui attend une décision passe avant l'état de la machine : une
            // session peut être close — donc au repos — et avoir encore un
            // arbitrage d'inactivité à trancher, un écran de fin à lire, ou une
            // pause qui vient de sonner.
            if let pending = controller.idleArbitration {
                // FR-024 — l'arbitrage passe avant toute nouvelle session.
                idleArbitration(pending)
            } else if let completion = controller.completion {
                // US4, US6 — l'entrée vient d'être produite : on dit ce qu'elle
                // devient avant de rendre la liste.
                CompletionView(controller: controller, completion: completion) {
                    controller.expandedTaskID = nil
                    Task { await controller.finishTask() }
                }
            } else if controller.breakFinished {
                breakEnded
            } else {
                switch controller.phase {
                case .idle:
                    TaskLauncher(controller: controller,
                                 expanded: $controller.expandedTaskID)

                case .running(let remaining, let taskPageID):
                    // Un Pomodoro a une échéance : le cadran la montre. Un suivi
                    // libre n'en a pas — un anneau y serait une promesse fausse,
                    // et c'est le temps écoulé qui devient le sujet de l'écran.
                    if let remaining {
                        pomodoro(remaining, taskPageID)
                    } else {
                        tracker(taskPageID)
                    }

                case .breakSuggested(let kind):
                    // Rien ne tourne : on propose de commencer la pause, jamais
                    // de l'arrêter — c'est ce bouton d'arrêt fantôme qui échouait.
                    SessionPanel(title: kind.isLong ? "Pause longue proposée" : "Pause proposée",
                                 caption: "Tu as gagné une pause") {
                        CounterPill(text: "\(controller.suggestedBreakMinutes) min")
                    } note: {
                        EmptyView()
                    } actions: {
                        HStack(spacing: 8) {
                            Button { Task { await controller.startBreak(kind) } } label: {
                                Text("Prendre une pause").controlLabel()
                            }
                            .buttonStyle(.borderedProminent)
                            Button { Task { await resume() } } label: {
                                Text("Repartir").controlLabel()
                            }
                        }
                    }

                case .onBreak(let remaining, let isLong):
                    SessionPanel(title: isLong ? "Pause longue" : "Pause") {
                        ring(remaining)
                    } note: {
                        EmptyView()
                    } actions: {
                        HStack(spacing: 8) {
                            // US2.2 : on doit pouvoir repartir immédiatement.
                            Button { Task { await resume() } } label: {
                                Text("Repartir").controlLabel()
                            }
                            Button { Task { await controller.stop() } } label: {
                                Text("Terminer la pause").controlLabel()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            // Une entrée en attente ne regarde que l'application : elle repart
            // d'elle-même, à intervalle régulier, jusqu'à passer. L'annoncer en
            // pied d'écran revenait à confier à l'utilisateur une inquiétude
            // dont il ne pouvait rien faire — le bouton « Réessayer » ne faisait
            // que devancer de quelques minutes ce qui allait arriver seul.
            //
            // Les échecs **définitifs** restent affichés : eux attendent une
            // décision qu'on ne peut pas prendre à sa place (FR-031).
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

    /// Le pomodoro en cours : la même mise en page que tous les autres écrans
    /// de session, le cadran à la place de la pastille.
    ///
    /// Il était seul à ne rien partager avec eux — titre collé en haut, cadran
    /// au milieu, bouton d'arrêt contre le bord gauche.
    @ViewBuilder
    private func pomodoro(_ remaining: Duration, _ taskPageID: String) -> some View {
        SessionPanel(title: controller.title(of: taskPageID)) {
            ring(remaining)
        } note: {
            EmptyView()
        } actions: {
            // FR-018 : le Pomodoro n'offre pas de pause.
            Button { Task { await controller.stop() } } label: {
                Text("Arrêter").controlLabel()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// La pause vient de sonner : repartir sur la même tâche, ou en changer.
    private var breakEnded: some View {
        SessionPanel(title: "Pause terminée",
                     caption: "La pause a duré…") {
            CounterPill(text: "\(controller.lastBreakMinutes) min")
        } note: {
            EmptyView()
        } actions: {
            // Empilés : « Relancer le pomodoro » ne tient pas à côté d'un second
            // bouton dans un panneau de 320 points, et les deux suites n'ont pas
            // le même poids — l'une reprend, l'autre s'en va.
            VStack(spacing: 8) {
                Button { Task { await controller.resumeAfterBreak() } } label: {
                    Text("Relancer le pomodoro").controlLabel()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                Button { controller.dismissBreakEnded() } label: {
                    Text("Changer de tâche").controlLabel()
                }
            }
        }
    }

    /// Le suivi libre en cours, bâti comme l'écran de fin : un en-tête discret,
    /// le chiffre au centre, et les suites en dessous, alignées sur lui.
    @ViewBuilder
    private func tracker(_ taskPageID: String) -> some View {
        SessionPanel(title: controller.title(of: taskPageID),
                     caption: "La session a commencé il y a…") {
            CounterPill(text: controller.elapsedLabel)
        } note: {
            // Sous le temps travaillé, en petit : depuis quand on s'est arrêté.
            // Le premier compte ce qui partira dans Notion, le second ne compte
            // que pour soi.
            if let paused = controller.pausedLabel {
                Text("En pause depuis \(paused)")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: paused)
            }
        } actions: {
            HStack(spacing: 8) {
                Button { Task { await controller.togglePause() } } label: {
                    Text(controller.isPaused ? "Reprendre" : "Pause").controlLabel()
                }
                Button { Task { await controller.stop() } } label: {
                    HStack(spacing: 4) {
                        Text("Terminé")
                        Image(systemName: "checkmark.circle")
                    }
                    .controlLabel()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Le cadran d'une durée visée : temps restant au centre, part d'arc pour
    /// ce qu'il en reste.
    private func ring(_ remaining: Duration) -> some View {
        TimerRing(label: SessionControls.format(remaining),
                  progress: fraction(remaining),
                  endsAt: controller.endsAt,
                  diameter: 150)
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
