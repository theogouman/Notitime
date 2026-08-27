import Foundation

/// Erreur remontée par le client Notion. Elle porte toujours son classement :
/// c'est lui, et non le texte, qui décide d'un réessai (FR-029).
public struct NotionError: Error, Equatable {
    public let responseClass: ResponseClass
    public let status: Int?
    public let code: String?
    public let message: String?
    /// Vrai quand Notion a répondu, fût-ce une erreur.
    ///
    /// Un `503` et une coupure de connexion sont tous deux transitoires, mais
    /// ils ne se réessaient pas de la même façon : le premier prouve qu'aucune
    /// page n'a été créée, le second ne prouve rien. Sans cette distinction, un
    /// réessai après coupure recréerait une page déjà existante (FR-028, R-06).
    public let hadResponse: Bool

    public init(responseClass: ResponseClass, status: Int? = nil,
                code: String? = nil, message: String? = nil, hadResponse: Bool = true) {
        self.responseClass = responseClass
        self.status = status
        self.code = code
        self.message = message
        self.hadResponse = hadResponse
    }

    /// Vrai quand la réponse prouve qu'aucune page n'a été créée (FR-028, R-06).
    public var provesNoSideEffect: Bool { responseClass.provesNoSideEffect }

    /// Le refresh a été refusé définitivement : l'utilisateur doit se reconnecter.
    public var isInvalidGrant: Bool { code == "invalid_grant" || message == "invalid_grant" }

    public static func decoding(_ underlying: String) -> NotionError {
        NotionError(responseClass: .permanent(.validation), message: "réponse illisible : \(underlying)")
    }
}

/// Fournit le jeton porteur et sait le renouveler. Implémenté par
/// `ConnectionService` ; une doublure suffit aux tests du client.
public protocol AuthorizationProvider: Sendable {
    func bearerToken() async throws -> String
    /// Tente un rafraîchissement. `false` si aucun nouveau jeton n'a pu être obtenu.
    @discardableResult
    func refreshAccessToken() async throws -> Bool
}
