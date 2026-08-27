import Foundation

// Les quatre frontières où la logique métier touche la machine. `NotitimeCore`
// n'en connaît que les protocoles ; `App/System/` fournit les implémentations
// réelles, les tests fournissent des doublures. C'est cette frontière qui rend
// les principes VI et VII applicables (voir `contracts/core-api.md`).

// MARK: - Transport HTTP

public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable, Equatable {
        case get = "GET", post = "POST", patch = "PATCH"
    }

    public var method: Method
    public var path: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, path: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var retryAfter: String? {
        headers.first { $0.key.caseInsensitiveCompare(NotionAPI.Header.retryAfter) == .orderedSame }?.value
    }
}

/// Émission d'une requête. Une erreur levée signifie **aucune réponse reçue**,
/// donc une issue indéterminée pour la file d'envoi (R-06).
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

// MARK: - Stockage des tokens

/// Les tokens vivent exclusivement dans le Keychain (principe III). Ce protocole
/// permet aux tests de couvrir le rafraîchissement et la déconnexion sans toucher
/// au trousseau de la machine.
public protocol TokenStore: Sendable {
    func accessToken() async throws -> String?
    func refreshToken() async throws -> String?
    func store(accessToken: String, refreshToken: String) async throws
    /// Déconnexion : supprime les deux tokens. Ne touche jamais à la file d'envoi.
    func clear() async throws
}

// MARK: - Inactivité

/// Délai depuis le dernier événement d'entrée système, et rien d'autre.
///
/// Aucune frappe, aucun écran, aucune application utilisée n'est observé : c'est
/// la contrainte de vie privée de la constitution (R-03).
public protocol InactivityMonitor: Sendable {
    func secondsSinceLastInput() async -> TimeInterval
}

// MARK: - Veille

public enum PowerEvent: Sendable, Equatable {
    /// Émis **avant** la mise en veille, ce qui laisse le temps d'horodater et de
    /// persister la transition (R-04).
    case willSleep
    case didWake
}

public protocol SleepObserver: Sendable {
    /// Flux des transitions d'alimentation, consommé par la machine à états.
    var events: AsyncStream<PowerEvent> { get }
}
