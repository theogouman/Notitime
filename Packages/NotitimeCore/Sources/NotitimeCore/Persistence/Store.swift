import Foundation
import SwiftData

/// Construction du magasin local.
///
/// Le conteneur est bâti par Core, et non par la cible applicative : c'est ce qui
/// permet de tester la file d'envoi et la restauration de session par `swift test`,
/// sans Xcode et sans fichier résiduel (R-08).
public enum NotitimeStore {

    /// Tous les modèles persistés. Un seul magasin, aucun token dedans.
    public static let schema = Schema([
        NotionConnection.self,
        DatabaseBinding.self,
        CachedTask.self,
        CachedProject.self,
        RecentTaskUse.self,
        ActiveSession.self,
        OutboxEntry.self,
        AppSettings.self
    ])

    /// Magasin de production, dans Application Support.
    public static func makeContainer(at url: URL? = nil) throws -> ModelContainer {
        let storeURL = try url ?? defaultStoreURL()
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Magasin en mémoire : tests hermétiques, aucun fichier écrit.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// `~/Library/Application Support/Notitime/Notitime.store`
    public static func defaultStoreURL() throws -> URL {
        let directory = try applicationSupportDirectory()
        return directory.appendingPathComponent("Notitime.store")
    }

    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let directory = base.appendingPathComponent("Notitime", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
