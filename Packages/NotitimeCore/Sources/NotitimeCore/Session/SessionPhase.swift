import Foundation

/// Ce que l'interface doit montrer d'une session (FR-025).
///
/// Dérivée de l'état réel de la machine, jamais posée à la main : afficher une
/// phase que la machine ne tient pas produit des commandes qui échouent — un
/// bouton d'arrêt sans session à arrêter.
public enum SessionPhase: Sendable, Equatable {
    case idle
    /// `remaining` est nul en mode Tracker, qui n'a pas de cible.
    case running(remaining: Duration?, taskPageID: String)
    case onBreak(remaining: Duration, isLong: Bool)
    /// Pause **proposée** après un pomodoro allé à son terme : rien ne tourne
    /// encore, l'utilisateur doit l'accepter ou repartir (FR-020).
    case breakSuggested(BreakKind)

    /// Vrai seulement quand une session ou une pause tourne réellement.
    ///
    /// C'est ce qui décide de l'affichage du bouton d'arrêt : le proposer hors
    /// de ces cas mène droit à un refus `nothingRunning`.
    public var offersStop: Bool {
        switch self {
        case .running, .onBreak: return true
        case .idle, .breakSuggested: return false
        }
    }

    /// Dérive la phase de l'état de la machine.
    ///
    /// L'ordre compte : une session en cours l'emporte sur une proposition de
    /// pause restée en attente, faute de quoi la proposition persisterait à
    /// l'écran par-dessus la session suivante.
    public static func derive(snapshot: SessionSnapshot?,
                              suggestedBreak: BreakKind?,
                              now: Date) -> SessionPhase {
        guard let snapshot else {
            return suggestedBreak.map(SessionPhase.breakSuggested) ?? .idle
        }

        let elapsed = now.timeIntervalSince(snapshot.startedAt)
        let remaining = snapshot.targetSeconds.map {
            Duration.seconds(max(0, Double($0) - elapsed))
        }

        if snapshot.isBreak {
            return .onBreak(remaining: remaining ?? .seconds(0), isLong: false)
        }
        return .running(remaining: remaining, taskPageID: snapshot.taskPageID)
    }
}
