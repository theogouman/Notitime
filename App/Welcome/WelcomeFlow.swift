import SwiftUI
import SwiftData
import NotitimeCore

/// Déroulé de l'accueil : quatre écrans, dans l'ordre.
@MainActor
final class WelcomeFlow: ObservableObject {

    enum Panel: Int, CaseIterable {
        case manifesto
        case template
        case connect
        case ready
    }

    @Published private(set) var panel: Panel
    /// Sens du dernier passage, pour que l'écran sortant parte du bon côté.
    @Published private(set) var forward = true

    init(initial: Panel = .manifesto) {
        panel = initial
    }

    func advance(to next: Panel) {
        forward = next.rawValue > panel.rawValue
        panel = next
    }
}
