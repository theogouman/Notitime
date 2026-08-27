import SwiftUI
import SwiftData
import NotitimeCore

/// T099 à T106 — panneau de réglages (US7).
///
/// Les valeurs par défaut doivent suffire : cet écran existe pour s'adapter,
/// jamais pour rendre l'application utilisable.
struct SettingsView: View {

    @ObservedObject var state: RootState
    /// Appelé après une déconnexion : la fenêtre revient à l'onglet Connexion.
    var onDisconnected: () -> Void = {}

    @Query private var stored: [AppSettings]
    @Query private var pending: [OutboxEntry]

    @State private var confirmingDisconnect = false

    private var settings: AppSettings? { stored.first }

    var body: some View {
        Form {
            if let settings {
                durations(settings)
                idle(settings)
                notifications(settings)
                tasks(settings)
                system(settings)
            } else {
                Text("Réglages indisponibles : le magasin local n'a pas pu être ouvert.")
                    .foregroundStyle(.secondary)
            }
            bindings
            connection
            journal
        }
        .formStyle(.grouped)
        .onChange(of: stored.first?.pomodoroMinutes) { _, _ in propagate() }
        .onChange(of: stored.first?.doneStatusValues) { _, _ in propagate() }
    }

    // MARK: - Durées (FR-018, US7.2)

    @ViewBuilder
    private func durations(_ settings: AppSettings) -> some View {
        Section("Durées") {
            HStack {
                Text("Préréglages")
                Spacer()
                ForEach(PomodoroPreset.allCases, id: \.self) { preset in
                    Button(preset.label) {
                        settings.apply(preset)
                        propagate()
                    }
                }
            }
            Stepper("Pomodoro : \(settings.pomodoroMinutes) min",
                    value: Binding(get: { settings.pomodoroMinutes },
                                   set: { settings.pomodoroMinutes = $0; propagate() }),
                    in: 1...180)
            Stepper("Pause courte : \(settings.shortBreakMinutes) min",
                    value: Binding(get: { settings.shortBreakMinutes },
                                   set: { settings.shortBreakMinutes = $0; propagate() }),
                    in: 1...60)
            Stepper("Pause longue : \(settings.longBreakMinutes) min",
                    value: Binding(get: { settings.longBreakMinutes },
                                   set: { settings.longBreakMinutes = $0; propagate() }),
                    in: 1...120)
            Stepper("Pause longue tous les \(settings.pomodorosBeforeLongBreak) pomodoros",
                    value: Binding(get: { settings.pomodorosBeforeLongBreak },
                                   set: { settings.pomodorosBeforeLongBreak = $0; propagate() }),
                    in: 1...12)
        }
    }

    // MARK: - Inactivité (FR-024, T100)

    @ViewBuilder
    private func idle(_ settings: AppSettings) -> some View {
        Section("Détection d'inactivité") {
            Toggle("En suivi libre", isOn: Binding(
                get: { settings.idleDetectionEnabledTracker },
                set: { settings.idleDetectionEnabledTracker = $0; propagate() }))
            Toggle("En Pomodoro", isOn: Binding(
                get: { settings.idleDetectionEnabledPomodoro },
                set: { settings.idleDetectionEnabledPomodoro = $0; propagate() }))
            Stepper("Seuil : \(settings.idleThresholdMinutes) min",
                    value: Binding(get: { settings.idleThresholdMinutes },
                                   set: { settings.idleThresholdMinutes = $0; propagate() }),
                    in: 1...120)
            Text("Une inactivité détectée n'est jamais retranchée d'office : "
                 + "Notitime vous demande de conserver ou de retrancher.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Notifications (FR-032, T101)

    @ViewBuilder
    private func notifications(_ settings: AppSettings) -> some View {
        Section("Notifications") {
            Toggle("Notification de fin", isOn: Binding(
                get: { settings.notificationsEnabled },
                set: { settings.notificationsEnabled = $0; propagate() }))
            Toggle("Son de fin", isOn: Binding(
                get: { settings.soundEnabled },
                set: { settings.soundEnabled = $0; propagate() }))
            Text("Le bundle n'étant pas signé, macOS peut refuser les notifications. "
                 + "Le son, lui, reste joué.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tâches (FR-009, FR-010, FR-011)

    @ViewBuilder
    private func tasks(_ settings: AppSettings) -> some View {
        Section("Tâches") {
            Toggle("Afficher aussi les tâches non assignées", isOn: Binding(
                get: { settings.showUnassignedTasks },
                set: { settings.showUnassignedTasks = $0; propagate() }))
            Stepper("Rafraîchir toutes les \(settings.taskRefreshIntervalMinutes) min",
                    value: Binding(get: { settings.taskRefreshIntervalMinutes },
                                   set: { settings.taskRefreshIntervalMinutes = $0; propagate() }),
                    in: 1...120)
            LabeledContent("Statuts à exclure en plus") {
                TextField("laissez vide : le schéma décide", text: Binding(
                    get: { settings.doneStatusValues.joined(separator: ", ") },
                    set: {
                        settings.doneStatusValues = $0.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        propagate()
                    }))
            }
            Text("Les statuts du groupe « terminé » de votre base sont déjà exclus. "
                 + "N'ajoutez ici que les autres — « À valider », par exemple. "
                 + "Un statut inconnu de la base est ignoré.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Système (FR-033, FR-034)

    @ViewBuilder
    private func system(_ settings: AppSettings) -> some View {
        Section("Système") {
            Toggle("Lancer à l'ouverture de session", isOn: Binding(
                get: { LoginItemService.isEnabled },
                set: { enabled in
                    Task { await LoginItemService.setEnabled(enabled, log: state.environment?.log) }
                }))
            if LoginItemService.requiresApproval {
                Text("macOS attend votre approbation dans Réglages Système › Général › "
                     + "Ouverture et extensions.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Raccourci de concentration") {
                TextField("Nom du raccourci", text: Binding(
                    get: { settings.focusShortcutName ?? "" },
                    set: { settings.focusShortcutName = $0.isEmpty ? nil : $0 }))
            }
            Text("Créez un raccourci dans l'app Raccourcis qui active votre mode "
                 + "Concentration, puis indiquez son nom. Son échec n'empêche jamais "
                 + "une session de démarrer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bases liées (FR-007, T104, T105)

    @ViewBuilder
    private var bindings: some View {
        Section("Bases Notion") {
            if let onboarding = state.onboarding {
                ForEach([DatabaseRole.tasks, .timeEntries, .projects], id: \.self) { role in
                    LabeledContent(SettingsView.label(role)) {
                        Text(onboarding.bindings[role] ?? "non liée")
                            .foregroundStyle(onboarding.bindings[role] == nil ? .secondary : .primary)
                    }
                }
                HStack(spacing: 6) {
                    // FR-007 — changer de base à tout moment, avec revalidation.
                    Button("Changer les bases…") {
                        Task { await onboarding.browseAccessibleSources() }
                    }
                    // FR-006a — re-résoudre une source disparue.
                    Button("Revalider") { Task { await onboarding.revalidate() } }
                }
                Text("Le changement d'une base revalide son schéma avant d'être accepté.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func label(_ role: DatabaseRole) -> String {
        switch role {
        case .tasks: return "Tâches"
        case .timeEntries: return "Time Entries"
        case .projects: return "Projets"
        }
    }

    // MARK: - Connexion (FR-008)

    @ViewBuilder
    private var connection: some View {
        Section("Connexion") {
            Button("Se déconnecter…") { confirmingDisconnect = true }
                .confirmationDialog(disconnectPrompt, isPresented: $confirmingDisconnect) {
                    Button("Se déconnecter", role: .destructive) {
                        Task {
                            await state.onboarding?.disconnect()
                            onDisconnected()
                        }
                    }
                    Button("Annuler", role: .cancel) {}
                }
            Text("Vos tokens sont effacés du trousseau. Les entrées en attente "
                 + "restent en file et repartiront à la prochaine connexion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// FR-008 : avertir si des entrées sont encore en attente d'envoi.
    private var disconnectPrompt: String {
        pending.isEmpty
            ? "Se déconnecter de Notion ?"
            : "\(pending.count) entrée(s) attendent d'être envoyées. Elles resteront en "
            + "file et repartiront à la prochaine connexion. Se déconnecter ?"
    }

    // MARK: - Journal (FR-037, T106)

    @ViewBuilder
    private var journal: some View {
        Section("Journal") {
            Button("Exporter le journal…") { Task { await exportLog() } }
            Text("Le journal ne contient ni token, ni code d'autorisation, ni titre de "
                 + "tâche — seulement des identifiants.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exportLog() async {
        guard let environment = state.environment else { return }
        let contents = await environment.log.exportedContents()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "notitime-journal.txt"
        panel.canCreateDirectories = true
        guard await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) == .OK,
              let url = panel.url else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Republie les réglages vers la machine et le cache : sans cela, un
    /// changement ne prendrait effet qu'au prochain lancement.
    private func propagate() {
        try? state.environment?.container.mainContext.save()
        Task { await state.session?.applySettings() }
    }
}
