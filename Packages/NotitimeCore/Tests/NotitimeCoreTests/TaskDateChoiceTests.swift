import XCTest
@testable import NotitimeCore

/// Choix de la date affichée dans la liste des tâches : l'échéance d'abord,
/// jamais ce que Notion tient lui-même.
final class TaskDateChoiceTests: XCTestCase {

    private func date(_ start: String) -> [String: Any] {
        ["type": "date", "date": ["start": start]]
    }

    func testPrefersDeadlineOverAnyOtherDate() throws {
        let properties: [String: Any] = [
            "Date de début": date("2026-01-10"),
            "Deadline": date("2026-02-20")
        ]
        let chosen = try XCTUnwrap(TaskDateChoice.date(in: properties))
        XCTAssertEqual(TaskDateChoice.parse("2026-02-20"), chosen)
    }

    func testIgnoresSystemDatesByType() {
        let properties: [String: Any] = [
            "Créé le": ["type": "created_time", "created_time": "2026-01-01T10:00:00.000Z"],
            "Modifié le": ["type": "last_edited_time",
                           "last_edited_time": "2026-01-02T10:00:00.000Z"]
        ]
        XCTAssertNil(TaskDateChoice.date(in: properties))
    }

    /// Une propriété *date* tenue à la main peut porter un nom de propriété
    /// système : elle n'est pas pour autant une échéance.
    func testIgnoresSystemDatesByName() {
        let properties: [String: Any] = [
            "Date de création": date("2026-01-01"),
            "Last edited time": date("2026-01-02")
        ]
        XCTAssertNil(TaskDateChoice.date(in: properties))
    }

    func testFallsBackToTheFirstRealDate() throws {
        let properties: [String: Any] = [
            "Planifié": date("2026-03-05"),
            "Date de création": date("2026-01-01")
        ]
        let chosen = try XCTUnwrap(TaskDateChoice.date(in: properties))
        XCTAssertEqual(TaskDateChoice.parse("2026-03-05"), chosen)
    }

    /// `properties` est un dictionnaire : sans départage, la date affichée
    /// changerait d'une lecture à l'autre pour la même tâche.
    func testChoiceIsStableBetweenReads() {
        let properties: [String: Any] = [
            "Revue": date("2026-04-01"),
            "Atelier": date("2026-05-01"),
            "Livraison": date("2026-06-01")
        ]
        let first = TaskDateChoice.date(in: properties)
        for _ in 0..<20 {
            XCTAssertEqual(TaskDateChoice.date(in: properties), first)
        }
        // « Livraison » annonce une échéance, les deux autres non.
        XCTAssertEqual(first, TaskDateChoice.parse("2026-06-01"))
    }

    func testReadsBothDayAndInstantForms() {
        XCTAssertNotNil(TaskDateChoice.parse("2026-08-28"))
        XCTAssertNotNil(TaskDateChoice.parse("2026-08-28T10:00:00.000+02:00"))
        XCTAssertNotNil(TaskDateChoice.parse("2026-08-28T10:00:00Z"))
        XCTAssertNil(TaskDateChoice.parse("pas une date"))
    }
}
