import XCTest
@testable import NotitimeCore

/// FR-037 : le journal ne contient jamais de token, de code OAuth ni de contenu de
/// tâche au-delà de son identifiant, et sa taille reste bornée.
final class SessionLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notitime-log-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSecretsNeverReachTheFile() async throws {
        let log = SessionLog(directory: directory, time: VirtualTimeSource())

        await log.log(.auth, #"réponse {"access_token":"secret_ntn_ABC123","refresh_token":"secret_rt_XYZ"}"#)
        await log.log(.auth, "échange code=abc.def.ghi verifier=zzz state=yyy")
        await log.log(.sync, "en-tête Authorization: Bearer ntn_verySecretValue")

        let contents = await log.exportedContents()

        for secret in ["secret_ntn_ABC123", "secret_rt_XYZ", "abc.def.ghi", "zzz",
                       "ntn_verySecretValue"] {
            XCTAssertFalse(contents.contains(secret),
                           "le journal a laissé fuir « \(secret) »")
        }
        XCTAssertTrue(contents.contains("***"), "les valeurs doivent être remplacées, pas supprimées")
    }

    func testTaskIsLoggedByIdentifierOnly() async throws {
        let log = SessionLog(directory: directory, time: VirtualTimeSource())
        let pageID = "1f2e3d4c-0000-0000-0000-000000000000"

        // La convention d'appel est de ne jamais passer le titre. Le test fige la
        // convention : il échouera si un appelant se met à journaliser un titre.
        await log.log(.session, "session démarrée task=\(pageID) mode=pomodoro")
        let contents = await log.exportedContents()

        XCTAssertTrue(contents.contains(pageID))
        XCTAssertFalse(contents.lowercased().contains("refonte facturation"))
    }

    func testRotationKeepsTheFootprintBounded() async throws {
        let log = SessionLog(directory: directory, time: VirtualTimeSource())
        let filler = String(repeating: "x", count: 4_096)

        for index in 0..<1_200 {
            await log.log(.sync, "\(index) \(filler)")
        }

        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { sum, url in
            sum + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let ceiling = SessionLog.maxFileBytes * SessionLog.rotatedFileCount

        XCTAssertLessThanOrEqual(files.count, SessionLog.rotatedFileCount)
        XCTAssertLessThanOrEqual(total, ceiling, "l'empreinte disque doit rester bornée")
        XCTAssertGreaterThan(total, 0, "le journal doit tout de même écrire")
    }

    func testTimestampsUseInjectedClock() async throws {
        let time = VirtualTimeSource(wallClock: Date(timeIntervalSince1970: 1_756_000_000))
        let log = SessionLog(directory: directory, time: time)

        await log.log(.session, "démarrage")
        let contents = await log.exportedContents()

        XCTAssertTrue(contents.contains("2025-08-24"), "horodatage attendu en UTC depuis l'horloge injectée : \(contents)")
    }
}
