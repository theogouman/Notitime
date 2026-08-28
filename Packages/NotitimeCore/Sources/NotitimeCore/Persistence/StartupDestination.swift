import Foundation

/// Ce que le lancement doit montrer.
///
/// Une seule règle, énoncée une fois : sans compte relié l'accueil, avec un
/// compte mais des bases à désigner la configuration, et sinon rien du tout —
/// l'application vit dans la barre de menus.
public enum StartupDestination: Sendable, Equatable {
    case welcome
    case configuration
    case nothing

    public static func decide(for readiness: AppReadiness) -> StartupDestination {
        switch readiness {
        case .needsConnection: return .welcome
        case .needsBinding: return .configuration
        case .ready: return .nothing
        }
    }
}
