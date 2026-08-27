import Foundation
import AppKit
import NotitimeCore

/// T079 — veille et réveil du système (R-04).
///
/// `NSWorkspace.willSleepNotification` est **synchrone du point de vue du
/// système** : macOS laisse un court instant aux observateurs avant de suspendre
/// la machine. C'est pourquoi la clôture de session doit être persistée dans
/// cette fenêtre, et non reportée à une tâche qui ne s'exécutera jamais.
@MainActor
final class WorkspaceSleepObserver {

    private var observers: [NSObjectProtocol] = []
    private let onSleep: @MainActor () async -> Void
    private let onWake: @MainActor () async -> Void

    init(onSleep: @escaping @MainActor () async -> Void,
         onWake: @escaping @MainActor () async -> Void) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // `Task` sans détachement : on reste sur le fil principal, dans la
            // fenêtre que le système accorde avant de suspendre.
            Task { @MainActor in await self.onSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.onWake() }
        })
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
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
