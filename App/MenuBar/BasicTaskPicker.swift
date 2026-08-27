import SwiftUI
import NotitimeCore

/// T056 — liste brute de sélection de tâche.
///
/// Volontairement sommaire : ni recherche, ni section « Récentes », ni filtre.
/// C'est l'US3 qui rendra la sélection confortable ; ici il s'agit seulement de
/// pouvoir choisir une tâche et démarrer (FR-015).
struct BasicTaskPicker: View {

    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tâche").font(.caption).foregroundStyle(.secondary)

            if controller.isLoadingTasks {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Chargement des tâches…").font(.callout)
                }
            } else if controller.tasks.isEmpty {
                // FR-015a : jamais de liste vide muette.
                Text("Aucune tâche à proposer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Recharger") { Task { await controller.loadTasks() } }
            } else {
                Picker("Tâche", selection: $controller.selectedTaskID) {
                    ForEach(controller.tasks) { task in
                        Text(task.title).tag(Optional(task.id))
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
                BasicTaskPicker(controller: controller)
                HStack(spacing: 6) {
                    Button("Démarrer 25 min") { Task { await controller.startPomodoro(minutes: 25) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.selectedTaskID == nil)
                    Button("5 min") { Task { await controller.startPomodoro(minutes: 5) } }
                        .disabled(controller.selectedTaskID == nil)
                }

            case .running(let remaining, let taskTitle):
                Text(taskTitle).font(.callout).lineLimit(1)
                Text(SessionControls.format(remaining))
                    .font(.system(.title2, design: .monospaced))
                // FR-018 : en Pomodoro, « Arrêter » est la seule commande.
                Button("Arrêter") { Task { await controller.stop() } }

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
            if controller.pendingCount > 0 {
                Text("\(controller.pendingCount) entrée(s) en attente d'envoi.")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
