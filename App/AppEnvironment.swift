import Foundation
import SwiftData
import NotitimeCore

/// Câblage unique des composants de `NotitimeCore` avec leurs implémentations
/// système. C'est le seul endroit où les deux mondes se rencontrent.
@MainActor
final class AppEnvironment: ObservableObject {

    let container: ModelContainer
    let time: TimeSource
    let log: SessionLog
    let tokens: TokenStore
    let rateLimiter: RateLimiter
    let connection: ConnectionService
    let notion: NotionClient

    /// Version courte du bundle, pour le repère de lancement du journal.
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    init() throws {
        container = try NotitimeStore.makeContainer()
        time = SystemTimeSource()

        let logDirectory = try NotitimeStore.applicationSupportDirectory()
            .appendingPathComponent("Logs", isDirectory: true)
        log = SessionLog(directory: logDirectory, time: time)

        tokens = KeychainTokenStore()
        rateLimiter = RateLimiter(time: time)

        // Deux transports : l'un vers Notion, l'autre vers le backend OAuth.
        // Ils ne partagent que le protocole.
        let backendHost = (try? AppConfiguration.backendBaseURL())
            ?? URL(string: "https://auth.notitime.fr")!
        connection = ConnectionService(
            backend: BackendClient(transport: URLSessionTransport(host: backendHost)),
            tokens: tokens,
            log: log
        )
        notion = NotionClient(transport: URLSessionTransport(host: NotionAPI.host),
                              authorization: connection,
                              rateLimiter: rateLimiter,
                              log: log)
    }
}
