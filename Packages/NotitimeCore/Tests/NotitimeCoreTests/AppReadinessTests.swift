import XCTest
@testable import NotitimeCore

/// Ce qui autorise à démarrer une session.
///
/// La règle vivait dans une vue et ne regardait que les liaisons. Or une
/// déconnexion ne les efface pas — elles servent justement à la reconnexion :
/// le menu continuait donc de proposer de démarrer une session alors qu'aucun
/// compte Notion n'était relié, et l'entrée n'aurait eu nulle part où aller.
final class AppReadinessTests: XCTestCase {

    private let bound: Set<DatabaseRole> = [.tasks, .timeEntries]

    /// Le défaut observé : des liaisons conservées, plus aucune connexion.
    func testBindingsWithoutAConnectionAreNotEnough() {
        XCTAssertEqual(AppReadiness.evaluate(isConnected: false, boundRoles: bound),
                       .needsConnection)
    }

    func testNothingAtAllAsksForTheConnectionFirst() {
        XCTAssertEqual(AppReadiness.evaluate(isConnected: false, boundRoles: []),
                       .needsConnection,
                       "connecter d'abord : désigner des bases n'a pas de sens sans workspace")
    }

    /// Time Entries est indispensable : sans elle, une session close n'aurait
    /// aucune base où être écrite.
    func testConnectedWithoutTheRequiredRolesAsksForBinding() {
        XCTAssertEqual(AppReadiness.evaluate(isConnected: true, boundRoles: [.tasks]),
                       .needsBinding(missing: [.timeEntries]))
        XCTAssertEqual(AppReadiness.evaluate(isConnected: true, boundRoles: [.timeEntries]),
                       .needsBinding(missing: [.tasks]))
    }

    /// Projets reste optionnel (FR-005).
    func testProjectsIsNotRequired() {
        XCTAssertEqual(AppReadiness.evaluate(isConnected: true, boundRoles: bound), .ready)
    }

    func testOnlyReadinessAllowsASession() {
        XCTAssertTrue(AppReadiness.ready.allowsSession)
        XCTAssertFalse(AppReadiness.needsConnection.allowsSession)
        XCTAssertFalse(AppReadiness.needsBinding(missing: [.tasks]).allowsSession)
    }
}
