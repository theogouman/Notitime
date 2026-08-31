import SwiftUI
import AppKit
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
            connection
            journal
        }
        .formStyle(.grouped)
        .onChange(of: stored.first?.sessionMinutes) { _, _ in propagate() }
        .onChange(of: stored.first?.doneStatusValues) { _, _ in propagate() }
    }

    // MARK: - Durées (FR-018, US7.2)

    /// Les durées ne se choisissent plus dans une liste de préréglages.
    ///
    /// « 25 / 5 / 15 » et « 50 / 10 / 20 » décidaient de trois choses à la fois,
    /// et la durée qu'on réglait à la main apparaissait comme une troisième carte
    /// au lancement sans que rien ne l'annonce. Ici, la question est posée en
    /// clair et les durées proposées sont là, modifiables une à une.
    @ViewBuilder
    private func durations(_ settings: AppSettings) -> some View {
        Section {
            LabeledContent("Quelle durée pour tes sessions ?") {
                pillGroup {
                    ForEach(Array(settings.sessionDurations.enumerated()), id: \.offset) { rank, value in
                        DurationPill(minutes: Binding(
                            get: { value },
                            set: { replaceSession(at: rank, with: $0, in: settings) }),
                                     isLeading: rank == 0)
                    }
                }
            }
            LabeledContent("Quelle durée pour tes pauses ?") {
                pillGroup {
                    DurationPill(minutes: Binding(get: { settings.shortBreakMinutes },
                                                  set: { settings.shortBreakMinutes = $0; propagate() }),
                                 range: 1...60,
                                 unit: "min",
                                 isLeading: true)
                }
            }
        } header: {
            header("Durées du Pomodoro", "Personnalise les durées de tes sessions.")
        }
    }

    /// L'écrin des pastilles : clair, pour que les durées s'en détachent.
    ///
    /// Deux gris l'un sur l'autre ne font pas un contraste — le groupe et les
    /// pastilles se confondaient. Le groupe prend donc le fond des contrôles,
    /// clair en thème clair, et les pastilles restent le seul relief.
    @ViewBuilder
    private func pillGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }

    /// L'en-tête d'une section : son nom, puis ce qu'elle règle en une phrase.
    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
        // Sans quoi le style groupé compose l'en-tête en capitales, sous-texte
        // compris — une phrase entière en capitales ne se lit plus.
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Inactivité (FR-024, T100)

    @ViewBuilder
    private func idle(_ settings: AppSettings) -> some View {
        Section {
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
        } header: {
            header("Détection d'inactivité",
                   "Notre système identifie les moments où tu n'es pas actif "
                   + "pour calculer le vrai temps passé")
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
            Toggle("N'afficher que les tâches qui me sont assignées", isOn: Binding(
                get: { settings.onlyAssignedToMe },
                set: { settings.onlyAssignedToMe = $0; propagate() }))
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
    /// Remplace une durée proposée, en gardant la liste propre.
    ///
    /// Écrire une valeur déjà présente la ferait disparaître au tri suivant :
    /// deux pastilles portant 30 minutes n'ont aucun sens, et la liste doit
    /// rester celle qu'on voit.
    private func replaceSession(at rank: Int, with value: Int, in settings: AppSettings) {
        var durations = settings.sessionDurations
        guard durations.indices.contains(rank), !durations.contains(value) else { return }
        durations[rank] = value
        settings.sessionMinutes = durations.sorted()
        propagate()
    }

    private func propagate() {
        try? state.environment?.container.mainContext.save()
        Task { await state.session?.applySettings() }
    }
}
