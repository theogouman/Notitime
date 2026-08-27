import Foundation

/// Cause d'un échec définitif : aucun réessai ne la résoudra.
public enum PermanentFailure: String, Equatable, Sendable {
    /// `400` — le corps envoyé ne satisfait pas le schéma de la source.
    case validation
    /// `403` — permissions retirées, ou capacité absente de l'intégration.
    case forbidden
    /// `404` — source ou page introuvable.
    case notFound
}

/// Classement d'une réponse Notion, tel que fixé par `contracts/notion-api.md`.
///
/// Ce type est le point de décision unique de la file d'envoi : un `transient`
/// est réessayé indéfiniment (principe IV — une session ne se perd jamais), un
/// `permanent` ne l'est jamais (FR-029).
public enum ResponseClass: Equatable, Sendable {
    case success
    /// Réessayable sans limite. `retryAfter` provient de l'en-tête sur un `429`.
    case transient(retryAfter: Duration?)
    case permanent(PermanentFailure)
    /// `401` — un rafraîchissement de token puis un unique rejeu.
    case unauthorized

    /// Vrai quand la réponse **prouve** qu'aucune page n'a été créée.
    ///
    /// C'est ce qui dispense le réessai correspondant de la vérification
    /// d'idempotence : seule une issue indéterminée l'impose (FR-028, R-06).
    public var provesNoSideEffect: Bool {
        switch self {
        case .permanent, .unauthorized: return true
        case .success, .transient: return false
        }
    }

    /// `404`. Définitif pour la file d'envoi, mais pas pendant la duplication du
    /// template : la page peut n'être pas encore visible le temps de la copie.
    public var isNotFound: Bool { self == .permanent(.notFound) }
}

public enum ResponseClassifier {

    /// Classe une réponse HTTP reçue de Notion.
    public static func classify(status: Int, retryAfterHeader: String? = nil) -> ResponseClass {
        switch status {
        case 200..<300:
            return .success
        case 401:
            return .unauthorized
        case 429:
            return .transient(retryAfter: parseRetryAfter(retryAfterHeader))
        case 400:
            return .permanent(.validation)
        case 403:
            return .permanent(.forbidden)
        case 404:
            return .permanent(.notFound)
        case 500..<600:
            return .transient(retryAfter: nil)
        default:
            // Tout statut non prévu est traité comme transitoire : préférer un
            // réessai inutile à la perte d'une entrée (principe IV).
            return .transient(retryAfter: nil)
        }
    }

    /// Une erreur de transport — pas de réponse du tout — est toujours transitoire,
    /// et laisse l'issue de la tentative **indéterminée** côté file d'envoi.
    public static func classify(transportError: Error) -> ResponseClass {
        .transient(retryAfter: nil)
    }

    static func parseRetryAfter(_ header: String?) -> Duration? {
        guard let header, let seconds = Double(header.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0 else { return nil }
        return .seconds(seconds)
    }
}
