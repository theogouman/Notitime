import Foundation

/// Accès au temps, injecté partout où une durée est mesurée ou attendue.
///
/// Deux horloges distinctes, pour deux usages qu'il ne faut jamais confondre (R-02) :
/// - `monotonic` mesure les durées et ne recule jamais, quoi qu'il arrive à l'horloge
///   du Mac (fuseau, heure d'été, correction NTP) ;
/// - `wallClock` horodate le début et la fin, stockés en UTC.
///
/// Sans cette injection, aucun scénario de durée n'est testable en CI : c'est la
/// condition du principe VII.
public protocol TimeSource: Sendable {
    /// Temps monotone depuis une origine arbitraire. Continue de courir en veille.
    var monotonic: Duration { get }

    /// Horloge murale, pour les horodatages persistés.
    var wallClock: Date { get }

    /// Attente. En test, elle avance un temps virtuel sans coût réel.
    func sleep(for duration: Duration) async throws
}

/// Implémentation de production, adossée à `ContinuousClock`.
public final class SystemTimeSource: TimeSource, @unchecked Sendable {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock().now
    }

    public var monotonic: Duration { clock.now - origin }

    public var wallClock: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }
}
