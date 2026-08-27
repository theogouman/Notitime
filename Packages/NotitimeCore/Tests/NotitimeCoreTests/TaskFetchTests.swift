import XCTest
@testable import NotitimeCore

/// T055 — chargement minimal des tâches pour l'US2.
final class TaskFetchTests: XCTestCase {

    private func makeFetch(_ transport: FixtureTransport) -> TaskFetch {
        TaskFetch(client: NotionClient(transport: transport,
                                       authorization: StaticAuthorization(),
                                       rateLimiter: .forTesting(VirtualTimeSource())),
                  mapper: PropertyMapper(map: [
                    .taskTitle: PropertyRef(id: "title", name: "Name", type: "title"),
                    .taskStatus: PropertyRef(id: "p-sta", name: "Status", type: "status"),
                    .taskAssignee: PropertyRef(id: "p-per", name: "Responsable", type: "people"),
                    .taskProject: PropertyRef(id: "p-prj", name: "Projets", type: "relation")
                  ]))
    }

    private func page(_ id: String, _ title: String) -> String {
        #"""
        {"object":"page","id":"\#(id)","properties":{
          "Name":{"id":"title","type":"title","title":[{"plain_text":"\#(title)"}]},
          "Status":{"id":"p-sta","type":"status","status":{"name":"En cours"}},
          "Responsable":{"id":"p-per","type":"people","people":[{"object":"user","id":"u-1"}]},
          "Projets":{"id":"p-prj","type":"relation","relation":[{"id":"proj-1"}]}}}
        """#.replacingOccurrences(of: "\n", with: "")
    }

    func testTasksAreReadWithTheirMappedProperties() async throws {
        let transport = FixtureTransport()
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: #"{"results":[\#(page("t-1", "Refonte facturation"))],"has_more":false}"#)

        let tasks = try await makeFetch(transport).load(from: "ds-tasks")

        XCTAssertEqual(tasks.count, 1)
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(task.id, "t-1")
        XCTAssertEqual(task.title, "Refonte facturation")
        XCTAssertEqual(task.statusValue, "En cours")
        XCTAssertEqual(task.assigneeIDs, ["u-1"])
        XCTAssertEqual(task.projectPageID, "proj-1")
    }

    /// La pagination est suivie jusqu'au bout : une liste tronquée ferait
    /// disparaître du menu des tâches parfaitement valides.
    func testPaginationIsFollowedToTheEnd() async throws {
        let transport = FixtureTransport()
        let path = NotionAPI.Path.queryDataSource("ds-tasks")
        await transport.enqueue(.post, path, status: 200,
                                json: #"{"results":[\#(page("t-1", "Une"))],"has_more":true,"next_cursor":"c1"}"#)
        await transport.enqueue(.post, path, status: 200,
                                json: #"{"results":[\#(page("t-2", "Deux"))],"has_more":false}"#)

        let tasks = try await makeFetch(transport).load(from: "ds-tasks")

        XCTAssertEqual(tasks.map(\.title), ["Une", "Deux"])
        let recorded = await transport.recorded
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: recorded[1].body ?? Data())
                                     as? [String: Any])
        XCTAssertEqual(second["start_cursor"] as? String, "c1")
    }

    /// Une page sans titre n'est pas proposable : l'utilisateur ne saurait pas
    /// ce qu'il sélectionne.
    func testPagesWithoutATitleAreSkipped() async throws {
        let transport = FixtureTransport()
        let untitled = #"{"object":"page","id":"t-x","properties":{"Name":{"id":"title","type":"title","title":[]}}}"#
        await transport.enqueue(.post, NotionAPI.Path.queryDataSource("ds-tasks"), status: 200,
                                json: #"{"results":[\#(untitled),\#(page("t-1", "Vraie"))],"has_more":false}"#)

        let tasks = try await makeFetch(transport).load(from: "ds-tasks")

        XCTAssertEqual(tasks.map(\.title), ["Vraie"])
    }
}
