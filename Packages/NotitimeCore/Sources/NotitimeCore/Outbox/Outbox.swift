import Foundation

/// Issue d'une tentative d'envoi.
public enum SendResult: Sendable, Equatable {
    /// La page existe dans Notion. L'entrée peut sortir de la file.
    case sent(pageID: String)
    /// FR-029 : erreur permanente. Aucun réessai ne la résoudra.
    case failedPermanently(cause: String)
    /// FR-029 : à réessayer. `attemptOutcome` décide si le réessai devra
    /// d'abord vérifier qu'aucune page n'a été créée (FR-028).
    case retryLater(attemptOutcome: AttemptOutcome, cause: String)
}

/// Envoi d'une entrée de temps vers Notion (FR-026 à FR-029).
///
/// **Ce que cet acteur ne fait pas** : il ne décide pas du moment du réessai ni
/// ne touche à la file persistée. Il exécute une tentative et rend son issue —
/// c'est ce qui le rend testable sans base ni horloge.
public actor Outbox {

    private let client: NotionClient
    private let composer: EntryComposer
    private let log: SessionLog?
    /// FR-026a : l'absence de capacité commentaire ne s'annonce qu'une fois.
    private var commentCapabilityReported = false

    public init(client: NotionClient, composer: EntryComposer, log: SessionLog? = nil) {
        self.client = client
        self.composer = composer
        self.log = log
    }

    /// Tente de créer la page, puis publie le commentaire si la session en
    /// justifie un.
    public func send(_ entry: ComposedEntry) async -> SendResult {
        await log?.log(.sync, "envoi entrée=\(entry.localID) durée=\(entry.durationMinutes)min "
                       + "issue=\(entry.outcome.rawValue)")
        do {
            let pageID = try await client.createPage(composer.pageBody(for: entry))
            await log?.log(.sync, "entrée créée page=\(pageID)")
            await publishComment(for: entry, on: pageID)
            return .sent(pageID: pageID)
        } catch let error as NotionError {
            let result = classify(error, for: entry)
            await trace(result, entry: entry, status: error.status)
            return result
        } catch {
            // Aucune réponse : on ne sait pas si la page existe. Le réessai
            // devra vérifier avant de recréer, sous peine de doublon (R-06).
            await log?.log(.error, "envoi sans réponse entrée=\(entry.localID) : "
                           + "issue indéterminée, réessai avec vérification")
            return .retryLater(attemptOutcome: .indeterminate, cause: "\(error)")
        }
    }

    /// Toute tentative laisse une trace de son issue.
    ///
    /// Le chemin heureux seul ne suffit pas : un envoi qui échoue est justement
    /// celui qu'on cherche à comprendre dans le journal.
    private func trace(_ result: SendResult, entry: ComposedEntry, status: Int?) async {
        let code = status.map { " http=\($0)" } ?? ""
        switch result {
        case .sent(let pageID):
            await log?.log(.sync, "entrée créée page=\(pageID)")
        case .failedPermanently(let cause):
            await log?.log(.error, "envoi refusé définitivement entrée=\(entry.localID)"
                           + "\(code) : \(cause)")
        case .retryLater(let attemptOutcome, let cause):
            await log?.log(.sync, "envoi à réessayer entrée=\(entry.localID)\(code) "
                           + "issue=\(attemptOutcome.rawValue) : \(cause)")
        }
    }

    private func classify(_ error: NotionError, for entry: ComposedEntry) -> SendResult {
        let cause = error.message ?? error.code ?? "erreur \(error.status ?? 0)"
        switch error.responseClass {
        case .permanent:
            return .failedPermanently(cause: cause)
        case .transient, .unauthorized, .success:
            // Une réponse de Notion prouve qu'aucune page n'a été créée, et
            // dispense le réessai de la vérification d'idempotence. Une requête
            // restée sans réponse ne prouve rien : elle impose la vérification.
            return .retryLater(attemptOutcome: error.hadResponse ? .explicitError : .indeterminate,
                               cause: cause)
        }
    }

    /// FR-026a — best-effort, strictement après la création.
    ///
    /// Aucun échec ici ne remet l'entrée en file : la page existe, la rejouer
    /// créerait un doublon. C'est le seul endroit du code où une erreur réseau
    /// est délibérément avalée.
    private func publishComment(for entry: ComposedEntry, on pageID: String) async {
        guard let text = composer.comment(for: entry) else { return }
        do {
            try await client.createComment(pageID: pageID, text: text)
            await log?.log(.sync, "commentaire publié page=\(pageID)")
        } catch let error as NotionError where error.responseClass == .permanent(.forbidden) {
            if !commentCapabilityReported {
                commentCapabilityReported = true
                await log?.log(.sync, "capacité commentaire absente de l'intégration : "
                               + "les entrées restent envoyées, sans commentaire")
            }
        } catch {
            await log?.log(.sync, "commentaire non publié page=\(pageID) — sans conséquence "
                           + "sur l'entrée, qui reste envoyée")
        }
    }
}
