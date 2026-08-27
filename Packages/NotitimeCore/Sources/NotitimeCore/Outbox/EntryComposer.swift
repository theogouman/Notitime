import Foundation

/// Entrée de temps composée, prête à être mise en file puis envoyée.
public struct ComposedEntry: Sendable, Equatable {
    public let localID: UUID
    public let taskPageID: String
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationMinutes: Int
    public let mode: SessionMode
    public let outcome: SessionOutcome
    public let shortenReason: ShortenReason?
    public let subtractedIdleMinutes: Int

    public init(localID: UUID, taskPageID: String, title: String, startedAt: Date,
                endedAt: Date, durationMinutes: Int, mode: SessionMode,
                outcome: SessionOutcome, shortenReason: ShortenReason?,
                subtractedIdleMinutes: Int) {
        self.localID = localID
        self.taskPageID = taskPageID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMinutes = durationMinutes
        self.mode = mode
        self.outcome = outcome
        self.shortenReason = shortenReason
        self.subtractedIdleMinutes = subtractedIdleMinutes
    }
}

/// Compose une entrée de temps à partir d'une session close (FR-026).
///
/// Séparé de l'envoi : ce qui est écrit dans Notion se vérifie ici, sans réseau.
public struct EntryComposer: Sendable {

    /// Longueur maximale du titre généré (data-model §3).
    public static let maximumTitleLength = 200

    private let mapper: PropertyMapper
    public let dataSourceID: String
    private let personUserID: String
    /// Options réellement présentes sur la propriété de statut de la source.
    private let statusOptions: [String]
    private let taskTitleLookup: @Sendable (String) -> String?

    public init(mapper: PropertyMapper, dataSourceID: String, personUserID: String,
                statusOptions: [String] = [],
                taskTitleLookup: @escaping @Sendable (String) -> String?) {
        self.mapper = mapper
        self.dataSourceID = dataSourceID
        self.personUserID = personUserID
        self.statusOptions = statusOptions
        self.taskTitleLookup = taskTitleLookup
    }

    // MARK: - Composition

    public func compose(_ session: CompletedSession) -> ComposedEntry {
        ComposedEntry(localID: session.localID,
                      taskPageID: session.taskPageID,
                      title: title(for: session),
                      startedAt: session.startedAt,
                      endedAt: session.endedAt,
                      durationMinutes: EntryComposer.minutes(session.effectiveSeconds),
                      mode: session.mode,
                      outcome: session.outcome,
                      shortenReason: session.shortenReason,
                      subtractedIdleMinutes: EntryComposer.minutes(session.subtractedIdleSeconds))
    }

    /// Minutes entières, arrondies au plus proche : une session de 90 s vaut
    /// 2 minutes, pas 1 — tronquer sous-déclarerait systématiquement le temps.
    public static func minutes(_ seconds: Int) -> Int {
        Int((Double(seconds) / 60).rounded())
    }

    /// `<tâche> — <durée> min — <date et heure de début>` (data-model §3).
    ///
    /// La troncature porte sur le titre de la tâche : durée et heure sont ce qui
    /// distingue deux sessions du même jour sur la même tâche.
    private func title(for session: CompletedSession) -> String {
        let minutes = EntryComposer.minutes(session.effectiveSeconds)
        let stamp = EntryComposer.titleDateFormatter.string(from: session.startedAt)
        let suffix = " — \(minutes) min — \(stamp)"
        let task = taskTitleLookup(session.taskPageID) ?? "Tâche"

        let room = EntryComposer.maximumTitleLength - suffix.count
        guard room > 1, task.count > room else { return task + suffix }
        return String(task.prefix(max(1, room - 1))) + "…" + suffix
    }

    static let titleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Corps de la requête

    /// Corps de `POST /v1/pages`. Le parent est une **source**, jamais une base.
    public func pageBody(for entry: ComposedEntry) -> [String: Any] {
        var properties: [String: Any] = [:]

        func put(_ pair: (String, [String: Any])?) {
            guard let pair else { return }
            properties[pair.0] = pair.1
        }

        put(mapper.titleValue(.entryTitle, entry.title))
        put(mapper.relationValue(.entryTask, [entry.taskPageID]))
        put(mapper.dateValue(.entryStart, entry.startedAt))
        put(mapper.dateValue(.entryEnd, entry.endedAt))
        put(mapper.numberValue(.entryDuration, entry.durationMinutes))
        put(mapper.selectOrStatusValue(.entryType, methodName(for: entry.mode)))
        put(mapper.selectOrStatusValue(.entryStatus, statusName(for: entry.outcome)))
        // Cas limite « invité » : un compte invité n'apparaît pas dans la
        // propriété Personne de la base, et Notion refuse alors l'écriture. On
        // omet la propriété plutôt que d'échouer : mieux vaut une entrée sans
        // responsable qu'aucune entrée (T108).
        if !personUserID.isEmpty {
            put(mapper.peopleValue(.entryPerson, [personUserID]))
        }
        put(mapper.richTextValue(.entryLocalID, entry.localID.uuidString))

        return ["parent": ["data_source_id": dataSourceID], "properties": properties]
    }

    private func methodName(for mode: SessionMode) -> String {
        switch mode {
        case .pomodoro: return "Pomodoro"
        case .tracker: return "Tracker"
        }
    }

    /// Projette le résultat de session sur les options réellement disponibles.
    ///
    /// Une propriété de type `status` n'accepte **que** ses options existantes :
    /// contrairement à un `select`, l'API n'en crée pas à la volée, et écrire
    /// « Complété » dans un statut qui propose « Terminée » échoue en 400. On
    /// reconnaît donc l'option par fragment, et l'on ne retombe sur la valeur
    /// canonique de la spec que si la source n'annonce aucune option.
    func statusName(for outcome: SessionOutcome) -> String {
        let canonical = outcome.notionStatus ?? ""
        guard !statusOptions.isEmpty else { return canonical }

        let hints: [String]
        switch outcome {
        case .ranToTerm: hints = ["complét", "complet", "terminé", "termine", "fini", "done", "fait"]
        case .shortened: hints = ["écourt", "ecourt", "interromp", "annul", "partiel", "stopp", "cancel"]
        case .ignored: return canonical
        }

        for hint in hints {
            if let match = statusOptions.first(where: { $0.containsFolded(hint) }) { return match }
        }
        // Aucune option ne correspond : mieux vaut la valeur canonique, dont
        // l'échec sera explicite, qu'une option prise au hasard qui rendrait
        // l'entrée fausse sans que personne ne s'en aperçoive.
        return canonical
    }

    /// Filtre de vérification d'idempotence : l'identifiant local, porté par la
    /// propriété `rich_text` dédiée (FR-028).
    public func idempotencyQuery(for entry: ComposedEntry,
                                 includeArchived: Bool) -> [String: Any] {
        let name = mapper.name(.entryLocalID) ?? NotionAPI.defaultLocalIDPropertyName
        var body: [String: Any] = [
            "page_size": 1,
            "filter": ["property": name,
                       "rich_text": ["equals": entry.localID.uuidString]]
        ]
        // Notion exclut les pages en corbeille par défaut ; il faut le demander.
        if includeArchived { body["in_trash"] = true }
        return body
    }

    // MARK: - Commentaire (FR-026a)

    /// Motif d'écourtement et inactivité retranchée, publiés **après** création.
    ///
    /// Rien à dire d'une session allée à son terme sans retranchement : elle ne
    /// reçoit aucun commentaire.
    public func comment(for entry: ComposedEntry) -> String? {
        var parts: [String] = []

        switch entry.shortenReason {
        case .user: parts.append("Session écourtée : arrêt par l'utilisateur.")
        case .sleep: parts.append("Session écourtée : mise en veille de l'ordinateur.")
        case .unexpectedQuit: parts.append("Session écourtée : arrêt inopiné de l'application.")
        case nil: break
        }

        if entry.subtractedIdleMinutes > 0 {
            parts.append("Inactivité retranchée : \(entry.subtractedIdleMinutes) min.")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
