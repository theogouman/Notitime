import Foundation
import AppKit
import NotitimeCore

/// T103 — mode Concentration optionnel (FR-034, R-12).
///
/// macOS n'expose aucune API publique pour activer un mode Concentration. Le
/// seul chemin sanctionné passe par un **raccourci Shortcuts** que l'utilisateur
/// crée et désigne lui-même : l'application ne fait que le lancer.
///
/// Point R-12 levé : `shortcuts run` n'exige aucun entitlement particulier, mais
/// il ouvre un processus externe et peut échouer pour des raisons hors de notre
/// contrôle — raccourci renommé, supprimé, ou Shortcuts indisponible. **Un échec
/// ne doit jamais empêcher une session de démarrer** : la concentration est un
/// confort, le chronomètre est la fonction.
enum FocusModeService {

    static func run(shortcutNamed name: String?, log: SessionLog? = nil) async {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // On n'attend pas : un raccourci lent ne doit pas retarder le
            // démarrage du compte à rebours.
            await log?.log(.session, "raccourci de concentration lancé")
        } catch {
            await log?.log(.error, "raccourci de concentration indisponible : \(error) — "
                           + "la session démarre quand même")
        }
    }
}
