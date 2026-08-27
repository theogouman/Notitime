import Foundation

/// État de connexion vu par l'interface.
public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case connected(workspaceName: String, ownerName: String)
    /// Le token a été révoqué côté Notion : reconnexion nécessaire, file d'envoi
    /// intacte (US1.5, FR-008).
    case needsReconnection
}

/// Détenteur de la connexion Notion.
///
/// Fournit le jeton porteur au client, sait le renouveler, et déconnecte sur
/// refus définitif — **sans jamais toucher à la file d'envoi** : les entrées en
/// attente survivent à une reconnexion (FR-002, FR-008, cas limite du token).
public actor ConnectionService: AuthorizationProvider {

    public struct NotConnected: Error {}

    private let backend: BackendClient
    private let tokens: TokenStore
    private let log: SessionLog?
    private var onDisconnect: (@Sendable () async -> Void)?

    /// Métadonnées de la dernière autorisation, à persister par l'appelant.
    public private(set) var authorization: NotionAuthorization?
    public private(set) var state: ConnectionState = .disconnected

    public init(backend: BackendClient, tokens: TokenStore, log: SessionLog? = nil,
                onDisconnect: (@Sendable () async -> Void)? = nil) {
        self.backend = backend
        self.tokens = tokens
        self.log = log
        self.onDisconnect = onDisconnect
    }

    // MARK: - Connexion

    /// Termine le flux OAuth : échange le code, range les tokens au Keychain.
    @discardableResult
    public func connect(code: String, state verifierState: String, verifier: String) async throws -> NotionAuthorization {
        let result = try await backend.exchange(code: code, state: verifierState, verifier: verifier)
        guard let refresh = result.refreshToken else {
            // Sans refresh token, la connexion expirerait sans recours possible.
            throw NotionError(responseClass: .permanent(.validation),
                              message: "réponse d'autorisation sans refresh_token")
        }
        try await tokens.store(accessToken: result.accessToken, refreshToken: refresh)
        authorization = result
        state = .connected(workspaceName: result.workspaceName ?? "",
                           ownerName: result.owner?.user?.name ?? "")
        await log?.log(.auth, "connexion établie workspace=\(result.workspaceID)")
        return result
    }

    // MARK: - AuthorizationProvider

    public func bearerToken() async throws -> String {
        guard let token = try await tokens.accessToken() else { throw NotConnected() }
        return token
    }

    /// Tente un rafraîchissement.
    ///
    /// Un `invalid_grant` est définitif : l'utilisateur a révoqué l'accès dans
    /// Notion. On supprime les tokens et on bascule en `needsReconnection`, mais
    /// la file d'envoi n'est pas vidée — la reconnexion la libérera.
    @discardableResult
    public func refreshAccessToken() async throws -> Bool {
        guard let refreshToken = try await tokens.refreshToken() else {
            await markNeedsReconnection(reason: "aucun refresh token")
            return false
        }

        do {
            let renewed = try await backend.refresh(refreshToken: refreshToken)
            try await tokens.store(accessToken: renewed.accessToken,
                                   refreshToken: renewed.refreshToken ?? refreshToken)
            authorization = renewed
            await log?.log(.auth, "token rafraîchi")
            return true
        } catch let error as NotionError where error.isInvalidGrant {
            await markNeedsReconnection(reason: "invalid_grant")
            return false
        } catch let error as NotionError where error.responseClass.provesNoSideEffect {
            await markNeedsReconnection(reason: "refus définitif du rafraîchissement")
            return false
        }
        // Une panne transitoire remonte : les entrées restent en file et
        // réessaieront. Elle ne doit surtout pas déconnecter l'utilisateur.
    }

    /// T109 — cas limite multi-workspace : une nouvelle autorisation sur un
    /// **autre** workspace remplace la connexion.
    ///
    /// L'appelant doit avoir vidé ou envoyé la file de l'ancien workspace au
    /// préalable : les entrées y référencent des pages qui n'existent pas dans
    /// le nouveau, et les envoyer ensuite échouerait en `404`.
    public func isDifferentWorkspace(_ candidate: NotionAuthorization) -> Bool {
        guard let current = authorization else { return false }
        return current.workspaceID != candidate.workspaceID
    }

    // MARK: - Déconnexion

    /// Déconnexion volontaire. L'appelant a la responsabilité d'avertir si des
    /// entrées sont encore en attente (FR-008).
    public func disconnect() async throws {
        try await tokens.clear()
        authorization = nil
        state = .disconnected
        await log?.log(.auth, "déconnexion")
        await onDisconnect?()
    }

    private func markNeedsReconnection(reason: String) async {
        try? await tokens.clear()
        state = .needsReconnection
        await log?.log(.auth, "reconnexion nécessaire : \(reason)")
    }
}
