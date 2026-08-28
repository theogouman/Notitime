import SwiftUI
import NotitimeCore

/// Liste des tâches du menu : recherche locale, récentes en tête, puis le reste.
///
/// Une ligne se choisit d'un clic ; c'est le conteneur qui décide ce que ce clic
/// déclenche — ici, le dépliement du panneau de lancement.
struct TaskList: View {

    @ObservedObject var controller: SessionController
    @Binding var query: String
    /// Ligne survolée au clavier, distincte de la tâche dépliée.
    @Binding var highlighted: String?
    let select: (CachedTaskItem) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // FR-013 — filtre local, sans requête réseau.
            TextField("Rechercher une tâche…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onChange(of: query) { _, text in Task { await controller.search(text) } }
                .onSubmit { if let task = highlightedTask ?? controller.tasks.first { select(task) } }

            if controller.isLoadingTasks || controller.tasks.isEmpty {
                TaskListStates(controller: controller, query: $query)
                Spacer(minLength: 0)
            } else {
                rows
            }
        }
        .onAppear { searchFocused = true }
        // Rendre le focus en partant : un champ qui disparaît focalisé le lègue
        // à ce qui prend sa place, avec l'anneau bleu qui va avec.
        .onDisappear { searchFocused = false }
    }

    private var highlightedTask: CachedTaskItem? {
        controller.tasks.first { $0.id == highlighted }
    }

    /// FR-014 — les récentes forment une section à part, en tête.
    private var recents: [CachedTaskItem] {
        controller.tasks.filter { controller.recentIDs.contains($0.id) }
    }

    private var others: [CachedTaskItem] {
        controller.tasks.filter { !controller.recentIDs.contains($0.id) }
    }

    @ViewBuilder
    private var rows: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !recents.isEmpty {
                        section("Récentes", recents)
                        if !others.isEmpty { section("Toutes les tâches", others) }
                    } else {
                        ForEach(controller.tasks) { task in row(task) }
                    }
                }
            }
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                withAnimation(.linear(duration: 0.1)) { scroll.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [CachedTaskItem]) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.horizontal, 4)
        ForEach(items) { task in row(task) }
    }

    @ViewBuilder
    private func row(_ task: CachedTaskItem) -> some View {
        Button { select(task) } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .lineLimit(1)
                    if let project = controller.projectName(of: task) {
                        Text(project)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(highlighted == task.id ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(task.id)
    }
}
