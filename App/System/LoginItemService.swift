import Foundation
import ServiceManagement
import NotitimeCore

/// T102 — lancement à l'ouverture de session (FR-033, R-11).
///
/// L'état est lu depuis `SMAppService.status`, **jamais depuis une préférence
/// locale** : l'utilisateur peut révoquer le lancement automatique depuis les
/// Réglages Système, et une préférence stockée de notre côté mentirait alors.
enum LoginItemService {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Vrai quand macOS a besoin d'une approbation explicite de l'utilisateur.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool, log: SessionLog? = nil) async -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try await SMAppService.mainApp.unregister()
            }
            return isEnabled == enabled
        } catch {
            await log?.log(.error, "lancement à l'ouverture de session refusé : \(error)")
            return false
        }
    }
}
