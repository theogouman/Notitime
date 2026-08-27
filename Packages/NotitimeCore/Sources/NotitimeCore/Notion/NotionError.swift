import Foundation

/// Erreur remontée par le client Notion. Elle porte toujours son classement :
/// c'est lui, et non le texte, qui décide d'un réessai (FR-029).
public struct NotionError: Error, Equatable {
    public let responseClass: ResponseClass
    public let status: Int?
    public let code: String?
    public let message: String?

    public init(responseClass: ResponseClass, status: Int? = nil,
                code: String? = nil, message: String? = nil) {
        self.responseClass = responseClass
        self.status = status
        self.code = code
        self.message = message
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
