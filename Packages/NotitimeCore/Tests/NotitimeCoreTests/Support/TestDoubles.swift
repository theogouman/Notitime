import Foundation
@testable import NotitimeCore

/// Horloge virtuelle : `sleep` avance le temps instantanément.
///
/// Sans elle, chaque test de durée coûterait sa durée réelle, et la suite ne
/// tournerait pas en CI en quelques secondes (principe VII).
final class VirtualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _monotonic: Duration
    private var _wallClock: Date
    private(set) var sleepCount = 0

    init(start: Duration = .zero, wallClock: Date = Date(timeIntervalSince1970: 1_756_000_000)) {
        _monotonic = start
        _wallClock = wallClock
    }

    var monotonic: Duration { lock.withLock { _monotonic } }
    var wallClock: Date { lock.withLock { _wallClock } }

    func sleep(for duration: Duration) async throws {
        guard duration > .zero else { return }
        lock.withLock {
            sleepCount += 1
            _monotonic += duration
            _wallClock = _wallClock.addingTimeInterval(duration.seconds)
        }
    }

    /// Avance le temps sans passer par une attente, pour piloter un scénario.
    func advance(by duration: Duration) {
        lock.withLock {
            _monotonic += duration
            _wallClock = _wallClock.addingTimeInterval(duration.seconds)
        }
    }
}

/// Rejoue des réponses enregistrées, indexées par méthode et chemin (R-09).
///
/// Passer par le protocole plutôt que par un `URLProtocol` enregistré globalement
/// garde les tests parallélisables et sans état partagé.
actor FixtureTransport: HTTPTransport {

    enum Outcome {
        case response(HTTPResponse)
        /// Aucune réponse reçue : issue **indéterminée** côté file d'envoi.
        case failure(Error)
    }

    struct UnexpectedRequest: Error { let method: String; let path: String }

    private var queued: [String: [Outcome]] = [:]
    private(set) var recorded: [HTTPRequest] = []

    static func key(_ method: HTTPRequest.Method, _ path: String) -> String {
        "\(method.rawValue) \(path)"
    }

    /// Empile une issue pour un couple méthode/chemin. Les issues sont consommées
    /// dans l'ordre, ce qui permet de scripter « échec puis succès ».
    func enqueue(_ method: HTTPRequest.Method, _ path: String, _ outcome: Outcome) {
        queued[FixtureTransport.key(method, path), default: []].append(outcome)
    }

    func enqueue(_ method: HTTPRequest.Method, _ path: String, status: Int,
                 headers: [String: String] = [:], json: String = "{}") {
        enqueue(method, path, .response(HTTPResponse(status: status, headers: headers,
                                                     body: Data(json.utf8))))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.append(request)
        let key = FixtureTransport.key(request.method, request.path)
        guard var outcomes = queued[key], !outcomes.isEmpty else {
            throw UnexpectedRequest(method: request.method.rawValue, path: request.path)
        }
        let outcome = outcomes.removeFirst()
        queued[key] = outcomes
        switch outcome {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    func requestCount(_ method: HTTPRequest.Method, _ path: String) -> Int {
        recorded.filter { $0.method == method && $0.path == path }.count
    }
}

/// Magasin de tokens en mémoire : les tests ne touchent jamais au trousseau.
/// Trousseau qui refuse tout accès, comme lorsque l'utilisateur ferme la demande
/// de mot de passe présentée par macOS.
///
/// Le bundle n'étant pas signé en v1, son identité de code change à chaque build
/// et macOS resollicite l'utilisateur : ce refus est un cas courant, pas une
/// panne exceptionnelle.
actor RefusingTokenStore: TokenStore {
    struct Refused: Error {}
    private(set) var clearCount = 0

    func accessToken() async throws -> String? { throw Refused() }
    func refreshToken() async throws -> String? { throw Refused() }
    func store(accessToken: String, refreshToken: String) async throws { throw Refused() }
    func clear() async throws { clearCount += 1 }
}

actor InMemoryTokenStore: TokenStore {
    private var access: String?
    private var refresh: String?
    private(set) var clearCount = 0

    init(access: String? = nil, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }

    func accessToken() async throws -> String? { access }
    func refreshToken() async throws -> String? { refresh }

    func store(accessToken: String, refreshToken: String) async throws {
        access = accessToken
        refresh = refreshToken
    }

    func clear() async throws {
        access = nil
        refresh = nil
        clearCount += 1
    }
}

/// Délai d'inactivité piloté par le test.
final class StubInactivityMonitor: InactivityMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var _seconds: TimeInterval

    init(seconds: TimeInterval = 0) { _seconds = seconds }

    func set(seconds: TimeInterval) { lock.withLock { _seconds = seconds } }
    func secondsSinceLastInput() async -> TimeInterval { lock.withLock { _seconds } }
}

/// Événements de veille émis à la demande.
final class StubSleepObserver: SleepObserver, @unchecked Sendable {
    let events: AsyncStream<PowerEvent>
    private let continuation: AsyncStream<PowerEvent>.Continuation

    init() {
        var captured: AsyncStream<PowerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    func emit(_ event: PowerEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
}

/// Persistance de session qui compte ses écritures.
///
/// FR-022 exige que l'état soit réécrit **avant** que le contrôle ne revienne à
/// l'appelant : compter les écritures est la seule façon de le vérifier sans
/// interrompre réellement le processus.
actor RecordingSessionPersistence: SessionPersistence {
    private(set) var writeCount = 0
    /// Double option : `nil` = jamais écrit ; `.some(nil)` = effacé explicitement.
    private(set) var stored: SessionSnapshot??

    func save(_ snapshot: SessionSnapshot?) async {
        writeCount += 1
        stored = .some(snapshot)
    }

    func load() async -> SessionSnapshot? {
        if case .some(let value) = stored { return value }
        return nil
    }
}

/// Transport qui respecte l'annulation coopérative, comme `URLSession`.
///
/// Indispensable pour reproduire le défaut de production : une requête émise
/// depuis une tâche annulée est abandonnée avec `NSURLErrorCancelled`, sans
/// jamais atteindre Notion.
actor CancellationAwareTransport: HTTPTransport {
    struct Cancelled: Error {}
    private let inner: FixtureTransport

    init(_ inner: FixtureTransport) { self.inner = inner }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if Task.isCancelled { throw Cancelled() }
        return try await inner.send(request)
    }
}

/// Magasin qui compte ses **lectures**.
///
/// Chaque lecture correspond, sur la machine, à un `SecItemCopyMatching` — donc
/// potentiellement à une demande de mot de passe du trousseau. Compter est la
/// seule façon de vérifier qu'une session complète n'en provoque qu'une.
actor CountingTokenStore: TokenStore {
    private var access: String?
    private var refresh: String?
    private(set) var accessReads = 0
    private(set) var refreshReads = 0
    private(set) var writes = 0

    init(access: String? = nil, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }

    var reads: Int { accessReads + refreshReads }

    func accessToken() async throws -> String? {
        accessReads += 1
        return access
    }

    func refreshToken() async throws -> String? {
        refreshReads += 1
        return refresh
    }

    func store(accessToken: String, refreshToken: String) async throws {
        writes += 1
        access = accessToken
        refresh = refreshToken
    }

    func clear() async throws {
        access = nil
        refresh = nil
    }
}


/// Fait s'écouler du temps **en battant le minuteur**, comme une session réelle.
///
/// Une session en cours reçoit un tick par seconde : la machine ne voit jamais
/// plusieurs minutes s'écouler entre deux battements. Avancer l'horloge sans
/// battre revient à simuler une suspension du processus — ce que la machine
/// détecte désormais, et à juste titre. S'arrête au premier résultat
/// significatif : une session close ne reçoit plus de ticks.
@discardableResult
func beat(_ machine: SessionMachine, _ time: VirtualTimeSource,
          for seconds: Int, step: Int = 20) async -> SessionResult {
    var remaining = seconds
    while remaining > 0 {
        let slice = min(step, remaining)
        time.advance(by: .seconds(slice))
        remaining -= slice
        let result = await machine.handle(.tick)
        if result != .none { return result }
    }
    return .none
}
