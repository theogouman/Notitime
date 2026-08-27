import SwiftUI
import NotitimeCore

/// FR-015a — aucun état de la liste n'est muet.
///
/// Trois situations, trois explications, chacune avec l'action qui en sort :
/// le premier chargement, la liste vide qualifiée par sa cause, et Notion
/// injoignable — où le cache reste utilisable pour démarrer une session.
struct TaskListStates: View {

    @ObservedObject var controller: SessionController
    @Binding var query: String

    var body: some View {
        if controller.isLoadingTasks {
            // Le popover est étroit : même traitement, une taille en dessous.
            ShimmerText(text: "Chargement des tâches…", font: .title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            VStack(alignment: .leading, spacing: 6) {
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
                        .controlSize(.small)
                    }
                    Button("Recharger") { Task { await controller.loadTasks() } }
                        .controlSize(.small)
                }

                // Le cache reste consultable : dire de quand il date évite de
                // prendre une liste périmée pour une liste vide.
                if let stamp = controller.lastSync {
                    Text("Dernière synchronisation à \(SessionController.timeFormatter.string(from: stamp)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
