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

/// Où mène le lancement, selon ce que l'application peut faire.
///
/// La règle avait dérivé : l'accueil était conditionné à « ne l'avoir jamais
/// terminé », si bien qu'un utilisateur déconnecté retombait sur la fenêtre de
/// configuration — un écran qui n'offre qu'un bouton de connexion là où
/// l'accueil explique et conduit.
final class StartupDestinationTests: XCTestCase {

    func testNoAccountLeadsToTheWelcome() {
        XCTAssertEqual(StartupDestination.decide(for: .needsConnection), .welcome)
    }

    func testAnAccountWithMissingDatabasesLeadsToTheConfiguration() {
        XCTAssertEqual(StartupDestination.decide(for: .needsBinding(missing: [.tasks])),
                       .configuration)
    }

    /// Rien à ouvrir : l'application vit dans la barre de menus, et lui imposer
    /// une fenêtre au lancement irait contre son principe même.
    func testAConfiguredApplicationOpensNothing() {
        XCTAssertEqual(StartupDestination.decide(for: .ready), .nothing)
    }
}
