import Foundation
import UserNotifications
import AppKit
import NotitimeCore

/// T058 — notification système et son en fin de pomodoro et de pause (FR-032).
///
/// L'autorisation est demandée à la première notification et non au lancement :
/// une application de barre de menus qui réclame une permission avant d'avoir
/// rien fait d'utile se fait refuser.
@MainActor
final class NotificationPresenter {

    private let log: SessionLog?
    private var authorizationRequested = false
    /// Le refus se constate une fois ; on cesse alors de solliciter le système.
    private var authorized = true
    /// Retenu le temps de la lecture.
    ///
    /// `NSSound(named:)?.play()` ne joue rien de façon fiable : `play()` rend la
    /// main immédiatement et l'objet temporaire est libéré avant la fin du son.
    /// C'est la raison pour laquelle aucun son ne se faisait entendre.
    private var sound: NSSound?

    /// FR-032 — le son est désactivable indépendamment de la notification.
    var soundEnabled = true

    init(log: SessionLog? = nil) {
        self.log = log
    }

    func pomodoroFinished(taskTitle: String, minutes: Int) async {
        await present(title: "Pomodoro terminé",
                      body: "\(minutes) min sur « \(taskTitle) ».")
    }

    func breakFinished(isLong: Bool) async {
        await present(title: isLong ? "Pause longue terminée" : "Pause terminée",
                      body: "Prêt à repartir.")
    }

    private func present(title: String, body: String) async {
        playSound()
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Le son système est déjà joué ci-dessus : le doubler serait pénible.
        content.sound = nil

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            await log?.log(.error, "notification non présentée : \(error)")
        }
    }

    /// Son indépendant de la notification : il reste audible même quand les
    /// notifications sont refusées — ce qui est le cas d'un bundle non signé.
    /// C'est aujourd'hui le seul retour de fin de session garanti.
    private func playSound() {
        guard soundEnabled else { return }
        guard let sound = NSSound(named: "Glass") ?? NSSound(named: "Ping") else { return }
        sound.stop()
        self.sound = sound
        sound.play()
    }

    private func ensureAuthorization() async -> Bool {
        guard authorized else { return false }
        guard !authorizationRequested else { return true }
        authorizationRequested = true

        do {
            authorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            if !authorized {
                await log?.log(.session, "notifications refusées par l'utilisateur : "
                               + "le son reste joué")
            }
            return authorized
        } catch {
            // Un bundle non signé se voit refuser l'accès au centre de
            // notifications : il n'a pas d'identité de code stable à laquelle
            // rattacher une autorisation. Ce n'est pas une raison d'interrompre
            // la session — le son, lui, reste joué.
            authorized = false
            let detail = (error as NSError)
            await log?.log(.error, "notifications indisponibles "
                           + "(\(detail.domain) code=\(detail.code)) : \(detail.localizedDescription) "
                           + "— bundle non signé ; le son de fin reste joué")
            return false
        }
    }
}
