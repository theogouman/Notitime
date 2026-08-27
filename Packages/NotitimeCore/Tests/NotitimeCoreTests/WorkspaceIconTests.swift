import XCTest
@testable import NotitimeCore

/// `workspace_icon` porte deux choses différentes sous un seul champ.
final class WorkspaceIconTests: XCTestCase {

    func testHTTPSIconIsAnImage() {
        XCTAssertEqual(WorkspaceIcon.parse("https://s3.amazonaws.com/notion/logo.png"),
                       .image(URL(string: "https://s3.amazonaws.com/notion/logo.png")!))
    }

    /// Le cas le plus fréquent : la plupart des workspaces ont un emoji.
    /// `URL(string:)` le rejette, et l'icône disparaissait sans bruit.
    func testEmojiIconIsKept() {
        XCTAssertEqual(WorkspaceIcon.parse("🎯"), .emoji("🎯"))
        XCTAssertEqual(WorkspaceIcon.parse(" 🚀 "), .emoji("🚀"))
    }

    /// Les icônes intégrées arrivent en chemin relatif, inutilisable tel quel.
    func testBuiltInIconIsResolvedAgainstNotion() {
        XCTAssertEqual(WorkspaceIcon.parse("/icons/database_gray.svg"),
                       .image(URL(string: "https://www.notion.so/icons/database_gray.svg")!))
    }

    func testAbsenceIsNotAnIcon() {
        XCTAssertEqual(WorkspaceIcon.parse(nil), .none)
        XCTAssertEqual(WorkspaceIcon.parse("   "), .none)
    }
}
