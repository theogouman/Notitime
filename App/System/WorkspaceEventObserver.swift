import Foundation
import AppKit
import NotitimeCore

/// T079 — événements système d'alimentation et de session (R-04).
///
/// Deux rôles distincts, délibérément séparés.
///
/// **Ce qui est traité** : la veille et le réveil annoncés par le système, et
/// rien d'autre. `NSWorkspace.willSleepNotification` est synchrone du point de
/// vue du système — macOS laisse un court instant aux observateurs avant de
/// suspendre la machine —, c'est pourquoi la clôture de session doit être
/// persistée dans cette fenêtre, et non reportée à une tâche qui ne s'exécutera
/// jamais.
///
/// **Ce qui est seulement observé** : la veille des écrans, le verrouillage, le
/// changement d'utilisateur. Aucun de ces événements n'est une veille système —
/// fermer le clapet avec un écran externe branché n'endort pas le Mac, et le
/// travail peut très bien continuer derrière un écran verrouillé. L'application
/// s'en tient à ce que le système annonce plutôt que de deviner ; mais elle les
/// journalise, sans quoi « la veille n'a pas eu lieu » et « la veille n'a pas
/// été traitée » seraient indiscernables dans le journal.
@MainActor
final class WorkspaceEventObserver {

    /// Un événement système observé, et ce que l'application en fait.
    private struct Observed {
        let name: Notification.Name
        /// Ce qu'on lit dans le journal.
        let label: String
        /// `nil` quand l'événement est seulement constaté.
        let action: (@MainActor () async -> Void)?
        /// Le verrouillage passe par le centre distribué, pas par NSWorkspace.
        let isDistributed: Bool
    }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let log: SessionLog
    private let onSleep: @MainActor () async -> Void
    private let onWake: @MainActor () async -> Void

    init(log: SessionLog,
         onSleep: @escaping @MainActor () async -> Void,
         onWake: @escaping @MainActor () async -> Void) {
        self.log = log
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        for event in events() {
            let center: NotificationCenter = event.isDistributed ? distributed : workspace
            let token = center.addObserver(forName: event.name, object: nil, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                // `Task` sans détachement : on reste sur le fil principal, dans
                // la fenêtre que le système accorde avant de suspendre.
                Task { @MainActor in
                    await self.log.log(.session, "système : \(event.label)")
                    await event.action?()
                }
            }
            observers.append((center, token))
        }
    }

    private func events() -> [Observed] {
        [
            Observed(name: NSWorkspace.willSleepNotification,
                     label: "veille annoncée — traitée",
                     action: { [weak self] in await self?.onSleep() }, isDistributed: false),
            Observed(name: NSWorkspace.didWakeNotification,
                     label: "réveil annoncé — traité",
                     action: { [weak self] in await self?.onWake() }, isDistributed: false),
            // Les écrans s'éteignent sans que la machine dorme : c'est le cas du
            // clapet fermé avec un écran externe, et du délai d'extinction.
            Observed(name: NSWorkspace.screensDidSleepNotification,
                     label: "écrans en veille — non traité, la machine tourne toujours",
                     action: nil, isDistributed: false),
            Observed(name: NSWorkspace.screensDidWakeNotification,
                     label: "écrans réveillés — non traité",
                     action: nil, isDistributed: false),
            // Changement rapide d'utilisateur : la session passe à l'arrière-plan,
            // le processus continue de tourner.
            Observed(name: NSWorkspace.sessionDidResignActiveNotification,
                     label: "session utilisateur inactive — non traité",
                     action: nil, isDistributed: false),
            Observed(name: NSWorkspace.sessionDidBecomeActiveNotification,
                     label: "session utilisateur active — non traité",
                     action: nil, isDistributed: false),
            Observed(name: NSWorkspace.willPowerOffNotification,
                     label: "extinction annoncée — non traité",
                     action: nil, isDistributed: false),
            // Verrouillage : aucune API publique de NSWorkspace ne l'expose, mais
            // le centre distribué le diffuse. Sans sandbox, l'observation est
            // permise ; elle le resterait avec, en lecture seule.
            Observed(name: Notification.Name("com.apple.screenIsLocked"),
                     label: "écran verrouillé — non traité, la machine tourne toujours",
                     action: nil, isDistributed: true),
            Observed(name: Notification.Name("com.apple.screenIsUnlocked"),
                     label: "écran déverrouillé — non traité",
                     action: nil, isDistributed: true)
        ]
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }
}

/// T081 — détection d'inactivité système (FR-024, R-03).
///
/// `CGEventSource.secondsSinceLastEventType` rend le temps écoulé depuis le
/// dernier événement clavier ou souris, **sans aucune autorisation** : c'est une
/// mesure agrégée, pas une lecture d'événements. Elle ne demande donc ni accès
/// à l'accessibilité, ni entitlement — point qui restait à vérifier dans R-03.
///
/// Le sondage n'a lieu que pendant une session : au repos, l'application
/// n'émet rien (SC-006).
@MainActor
final class EventInactivityMonitor {

    /// Un sondage toutes les 15 s : assez fin pour un seuil de plusieurs
    /// minutes, assez rare pour rester invisible côté consommation.
    static let pollInterval = Duration.seconds(15)

    private var task: Task<Void, Never>?
    private var reportedIdleSeconds = 0
    private let threshold: Int
    private let onIdle: @MainActor (Int) async -> Void

    init(thresholdSeconds: Int, onIdle: @escaping @MainActor (Int) async -> Void) {
        self.threshold = thresholdSeconds
        self.onIdle = onIdle
    }

    func start() {
        stop()
        reportedIdleSeconds = 0
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: EventInactivityMonitor.pollInterval)
                guard let self else { return }
                self.sample()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Ne signale que l'**accroissement** d'inactivité depuis le dernier
    /// rapport : sans cela, une même période serait comptée à chaque sondage.
    private func sample() {
        let idle = Int(EventInactivityMonitor.systemIdleSeconds())
        guard idle >= threshold else {
            reportedIdleSeconds = 0
            return
        }
        let increment = idle - reportedIdleSeconds
        guard increment > 0 else { return }
        reportedIdleSeconds = idle
        Task { @MainActor in await self.onIdle(increment) }
    }

    static func systemIdleSeconds() -> Double {
        // Le plus grand silence parmi les sources : bouger la souris sans
        // toucher au clavier reste de l'activité.
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}
