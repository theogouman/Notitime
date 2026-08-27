import SwiftUI
import NotitimeCore

/// T056 — liste brute de sélection de tâche.
///
/// Volontairement sommaire : ni recherche, ni section « Récentes », ni filtre.
/// C'est l'US3 qui rendra la sélection confortable ; ici il s'agit seulement de
/// pouvoir choisir une tâche et démarrer (FR-015).
struct BasicTaskPicker: View {

    @ObservedObject var controller: SessionController
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // FR-013 — filtre local, sans requête réseau.
            TextField("Rechercher une tâche…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { _, text in Task { await controller.search(text) } }

            if controller.isLoadingTasks {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Chargement des tâches…").font(.callout)
                }
            } else if controller.tasks.isEmpty {
                // FR-015a — jamais de liste vide muette, et une action pour en sortir.
                Text(controller.notice ?? "Aucune tâche à proposer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !query.isEmpty {
                        Button("Effacer la recherche") {
                            query = ""
                            Task { await controller.search("") }
                        }
                    }
                    Button("Recharger") { Task { await controller.loadTasks() } }
                }
            } else {
                Picker("Tâche", selection: $controller.selectedTaskID) {
                    ForEach(controller.tasks) { task in
                        // FR-014 — les récentes sont marquées et remontent en tête.
                        Text(controller.recentIDs.contains(task.id) ? "★ \(task.title)" : task.title)
                            .tag(Optional(task.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }
}

/// T057, T059 — contrôles de session du menu.
struct SessionControls: View {

    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.phase {
            case .idle:
                if let pending = controller.idleArbitration {
                    // FR-024 — l'arbitrage passe avant toute nouvelle session.
                    idleArbitration(pending)
                } else {
                    BasicTaskPicker(controller: controller)
                    HStack(spacing: 6) {
                        Button("Pomodoro") { Task { await controller.startPomodoro() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(controller.selectedTaskID == nil)
                        Button("Suivi libre") { Task { await controller.startTracker() } }
                            .disabled(controller.selectedTaskID == nil)
                    }
                }

            case .running(let remaining, let taskPageID):
                Text(controller.title(of: taskPageID)).font(.callout).lineLimit(1)
                Text(remaining == nil ? controller.elapsedLabel : SessionControls.format(remaining))
                    .font(.system(.title2, design: .monospaced))
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
                    Button("Repartir") { Task { await controller.startPomodoro(minutes: 25) } }
                    Button("Plus tard") { Task { await controller.dismissBreak() } }
                }

            case .onBreak(let remaining, let isLong):
                Text(isLong ? "Pause longue" : "Pause").font(.callout)
                Text(SessionControls.format(remaining))
                    .font(.system(.title2, design: .monospaced))
                HStack(spacing: 6) {
                    // US2.2 : on doit pouvoir repartir immédiatement.
                    Button("Repartir") { Task { await controller.startPomodoro(minutes: 25) } }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Échec : \(entry.title)").font(.caption).bold()
                    Text(entry.failureCause ?? "cause inconnue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let target = controller.selectedTaskID {
                        // FR-031 — réassigner à la tâche sélectionnée avant renvoi.
                        Button("Réassigner à la tâche choisie") {
                            Task { await controller.reassign(entry.localID, to: target) }
                        }
                        .controlSize(.small)
                    }
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
