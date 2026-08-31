import XCTest
import SwiftData
@testable import NotitimeCore

/// Les tâches écartées de la liste : une décision locale, réversible, qui
/// n'écrit rien dans Notion.
final class HiddenTaskTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        ModelContext(try NotitimeStore.makeInMemoryContainer())
    }

    func testHidingATaskRecordsIt() throws {
        let context = try makeContext()

        HiddenTask.hide("t-1", in: context)

        XCTAssertEqual(HiddenTask.identifiers(in: context), ["t-1"])
    }

    /// Masquer deux fois la même tâche n'écrit qu'une ligne : le geste peut se
    /// répéter — deux menus ouverts, un clic de trop — sans laisser de trace.
    func testHidingTwiceWritesASingleRow() throws {
        let context = try makeContext()

        HiddenTask.hide("t-1", in: context)
        HiddenTask.hide("t-1", in: context)

        let rows = try context.fetch(FetchDescriptor<HiddenTask>())
        XCTAssertEqual(rows.count, 1)
    }

    /// Annuler rend la tâche à la liste, et ne touche pas aux autres.
    func testShowingRemovesOnlyThatTask() throws {
        let context = try makeContext()
        HiddenTask.hide("t-1", in: context)
        HiddenTask.hide("t-2", in: context)

        HiddenTask.show("t-1", in: context)

        XCTAssertEqual(HiddenTask.identifiers(in: context), ["t-2"])
    }
}
