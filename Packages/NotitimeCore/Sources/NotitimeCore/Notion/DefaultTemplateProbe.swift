import Foundation

/// Faut-il créer les pages d'un rôle depuis le modèle par défaut de sa base ?
///
/// La réponse est constatée une fois à la liaison, puis rafraîchie à chaque
/// lancement : c'est une propriété de la base, qui peut recevoir un modèle par
/// défaut bien après avoir été liée. Une liaison plus ancienne que la détection
/// gardait sinon « non » pour toujours, et les entrées naissaient nues sans que
/// rien ne le signale.
///
/// Le rafraîchissement ne doit pas se retourner contre nous : Notion
/// injoignable un matin n'est pas la preuve qu'un modèle a disparu, et effacer
/// le drapeau priverait toutes les entrées suivantes de leur contenu.
public enum DefaultTemplateProbe {

    /// Ce que la lecture des modèles de la source a donné.
    public enum Outcome: Sendable, Equatable {
        case has(Bool)
        /// La liste n'a pas pu être lue — réseau, droits, quota.
        case unreadable
    }

    public static func decide(role: DatabaseRole, current: Bool, outcome: Outcome) -> Bool {
        // Seules les entrées de temps sont créées par l'application : les tâches
        // et les projets sont lus, jamais écrits.
        guard role == .timeEntries else { return false }
        switch outcome {
        case .has(let value): return value
        case .unreadable: return current
        }
    }
}
