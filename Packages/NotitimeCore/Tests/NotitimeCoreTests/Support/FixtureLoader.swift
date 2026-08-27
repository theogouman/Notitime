import Foundation
import XCTest
@testable import NotitimeCore

/// Charge une réponse enregistrée depuis `Tests/NotitimeCoreTests/Fixtures/`.
/// Aucun test n'atteint le réseau : le principe VII l'interdit en CI.
enum Fixture {

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json",
                                          subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name, withExtension: "json") else {
            XCTFail("fixture introuvable : \(name).json", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: try data(name))
    }
}

/// Fournisseur d'autorisation simple, pour les tests du client qui ne portent pas
/// sur le rafraîchissement lui-même.
actor StaticAuthorization: AuthorizationProvider {
    private var token: String
    private(set) var refreshCount = 0
    private let refreshSucceeds: Bool

    init(token: String = "ntn_test", refreshSucceeds: Bool = true) {
        self.token = token
        self.refreshSucceeds = refreshSucceeds
    }

    func bearerToken() async throws -> String { token }

    @discardableResult
    func refreshAccessToken() async throws -> Bool {
        refreshCount += 1
        if refreshSucceeds { token = "ntn_refreshed" }
        return refreshSucceeds
    }
}

extension RateLimiter {
    /// Limiteur adossé à une horloge virtuelle : les tests n'attendent jamais.
    static func forTesting(_ time: VirtualTimeSource) -> RateLimiter {
        RateLimiter(time: time)
    }
}
