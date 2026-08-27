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

    /// Jetons gardés en mémoire pour la durée de la session.
    ///
    /// Le trousseau reste leur seule persistance (principe III) : la mémoire
    /// n'en est que le relais. Sans ce relais, chaque requête HTTP provoquait un
    /// `SecItemCopyMatching`, donc — tant que l'identité de code n'est pas
    /// stable — une demande de mot de passe. Un cycle ordinaire en comptait six,
    /// et les réessais de la file en ajoutaient à chaque tentative.
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    /// Lectures en cours, partagées entre appelants simultanés : la file d'envoi
    /// et le cache de tâches démarrent ensemble et demanderaient sinon deux fois.
    private var pendingAccessRead: Task<String?, Error>?
    private var pendingRefreshRead: Task<String?, Error>?

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
        remember(access: result.accessToken, refresh: refresh)
        authorization = result
        state = .connected(workspaceName: result.workspaceName ?? "",
                           ownerName: result.owner?.user?.name ?? "")
        await log?.log(.auth, "connexion établie workspace=\(result.workspaceID)")
        return result
    }

    // MARK: - AuthorizationProvider

    public func bearerToken() async throws -> String {
        if let cachedAccessToken { return cachedAccessToken }
        guard let token = try await readAccessToken() else { throw NotConnected() }
        cachedAccessToken = token
        // Journalisé parce que c'est cette ligne qui doit rester unique : une
        // seconde occurrence sans reconnexion signalerait le retour du défaut.
        await log?.log(.auth, "jeton lu au trousseau")
        return token
    }

    /// Tente un rafraîchissement.
    ///
    /// Un `invalid_grant` est définitif : l'utilisateur a révoqué l'accès dans
    /// Notion. On supprime les tokens et on bascule en `needsReconnection`, mais
    /// la file d'envoi n'est pas vidée — la reconnexion la libérera.
    @discardableResult
    public func refreshAccessToken() async throws -> Bool {
        guard let refreshToken = try await currentRefreshToken() else {
            await markNeedsReconnection(reason: "aucun refresh token")
            return false
        }

        do {
            let renewed = try await backend.refresh(refreshToken: refreshToken)
            try await tokens.store(accessToken: renewed.accessToken,
                                   refreshToken: renewed.refreshToken ?? refreshToken)
            remember(access: renewed.accessToken, refresh: renewed.refreshToken ?? refreshToken)
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
        forget()
        authorization = nil
        state = .disconnected
        await log?.log(.auth, "déconnexion")
        await onDisconnect?()
    }

    private func markNeedsReconnection(reason: String) async {
        try? await tokens.clear()
        forget()
        state = .needsReconnection
        await log?.log(.auth, "reconnexion nécessaire : \(reason)")
    }

    // MARK: - Relais mémoire du trousseau

    /// Le jeton vient d'être écrit : le relire serait une sollicitation de plus
    /// pour une valeur déjà connue.
    private func remember(access: String, refresh: String) {
        cachedAccessToken = access
        cachedRefreshToken = refresh
    }

    /// Déconnexion ou révocation : le relais est vidé en même temps que le
    /// trousseau, sans quoi l'application continuerait d'agir au nom d'un compte
    /// qui n'est plus le sien.
    private func forget() {
        cachedAccessToken = nil
        cachedRefreshToken = nil
    }

    private func currentRefreshToken() async throws -> String? {
        if let cachedRefreshToken { return cachedRefreshToken }
        let token = try await readRefreshToken()
        cachedRefreshToken = token
        if token != nil { await log?.log(.auth, "refresh token lu au trousseau") }
        return token
    }

    /// Coalesce les lectures : les appelants arrivés pendant qu'une lecture est
    /// en cours attendent son résultat au lieu d'en déclencher une seconde.
    private func readAccessToken() async throws -> String? {
        if let pendingAccessRead { return try await pendingAccessRead.value }
        let read = Task { [tokens] in try await tokens.accessToken() }
        pendingAccessRead = read
        defer { pendingAccessRead = nil }
        return try await read.value
    }

    private func readRefreshToken() async throws -> String? {
        if let pendingRefreshRead { return try await pendingRefreshRead.value }
        let read = Task { [tokens] in try await tokens.refreshToken() }
        pendingRefreshRead = read
        defer { pendingRefreshRead = nil }
        return try await read.value
    }
}
