import Foundation

/// Limiteur de débit unique, traversé par **toutes** les requêtes Notion.
///
/// La limite Notion s'applique à l'intégration entière, pas à un sous-système :
/// ne limiter que la file d'envoi laisserait le rafraîchissement des tâches
/// provoquer des `429` en plein envoi. D'où un acteur unique, point d'application
/// vérifiable (FR-029, R-05).
///
/// Sur `429`, c'est **le seau entier** qui est suspendu, pas la seule requête
/// fautive : sinon une requête concurrente repartirait aussitôt dans le mur.
public actor RateLimiter {

    public static let defaultRatePerSecond = 3.0

    private let ratePerSecond: Double
    private let capacity: Double
    private let time: TimeSource

    private var tokens: Double
    private var lastRefill: Duration
    private var suspendedUntil: Duration?

    public init(time: TimeSource, ratePerSecond: Double = RateLimiter.defaultRatePerSecond) {
        precondition(ratePerSecond > 0, "le débit doit être strictement positif")
        self.time = time
        self.ratePerSecond = ratePerSecond
        // Capacité de 1 jeton : pas de rafale. Un seau de capacité `ratePerSecond`
        // autoriserait 3 requêtes instantanées puis 3 de plus dans la même seconde
        // glissante, soit un pic à 6 req/s. FR-029 se lit strictement.
        self.capacity = 1
        self.tokens = 1
        self.lastRefill = time.monotonic
    }

    /// Attend le droit d'émettre une requête. À appeler avant *chaque* appel Notion.
    public func acquire() async throws {
        while true {
            let wait = nextWait()
            if wait == .zero {
                tokens -= 1
                return
            }
            try await time.sleep(for: wait)
        }
    }

    /// Suspend le seau entier pour la durée demandée par Notion sur un `429`.
    public func suspend(for duration: Duration) {
        guard duration > .zero else { return }
        let until = time.monotonic + duration
        if let current = suspendedUntil, current > until { return }
        suspendedUntil = until
    }

    /// Durée d'attente avant de pouvoir consommer un jeton ; `.zero` si c'est possible tout de suite.
    private func nextWait() -> Duration {
        let now = time.monotonic
        if let until = suspendedUntil {
            if now < until { return until - now }
            suspendedUntil = nil
        }
        refill(now: now)
        if tokens >= 1 { return .zero }
        let missing = 1 - tokens
        return .seconds(missing / ratePerSecond)
    }

    private func refill(now: Duration) {
        let elapsed = now - lastRefill
        guard elapsed > .zero else { return }
        tokens = min(capacity, tokens + elapsed.seconds * ratePerSecond)
        lastRefill = now
    }
}

public extension Duration {
    /// Conversion en secondes flottantes, pour les calculs de débit et de durée.
    var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
