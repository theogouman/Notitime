import Foundation

/// Ce que Notitime peut faire, dans l'ordre où l'utilisateur doit s'en occuper.
///
/// La règle est ici, et non dans une vue, parce que deux surfaces en dépendent —
/// le menu de la barre de menus et la fenêtre de configuration — et qu'elles
/// divergeaient : le menu proposait de démarrer une session alors que le compte
/// Notion venait d'être déconnecté. Une déconnexion n'efface pas les liaisons,
/// qui servent justement à la reconnexion ; les compter comme une configuration
/// valide était l'erreur.
public enum AppReadiness: Sendable, Equatable {
    /// Aucun compte Notion relié : c'est la seule action qui ait un sens.
    case needsConnection
    /// Compte relié, mais il manque des bases indispensables.
    case needsBinding(missing: [DatabaseRole])
    case ready

    /// Rôles sans lesquels une session n'aurait nulle part où être écrite.
    /// Projets reste optionnel (FR-005).
    public static let requiredRoles: [DatabaseRole] = [.tasks, .timeEntries]

    public static func evaluate(isConnected: Bool, boundRoles: Set<DatabaseRole>) -> AppReadiness {
        guard isConnected else { return .needsConnection }
        let missing = requiredRoles.filter { !boundRoles.contains($0) }
        return missing.isEmpty ? .ready : .needsBinding(missing: missing)
    }

    /// Démarrer une session suppose une base où l'écrire **et** un compte pour
    /// l'y envoyer : rien d'autre n'autorise à lancer un minuteur.
    public var allowsSession: Bool { self == .ready }
}
