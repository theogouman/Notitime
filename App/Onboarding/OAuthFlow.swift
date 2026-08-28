import Foundation
import AuthenticationServices
import CryptoKit
import NotitimeCore

/// Flux d'autorisation Notion.
///
/// `ASWebAuthenticationSession` est le chemin sanctionné par Apple : session de
/// navigation gérée par le système, aucun port en écoute, aucun entitlement
/// supplémentaire (FR-001, R-01 du contrat OAuth).
///
/// Le `verifier` reproduit PKCE, que Notion ne propose pas nativement : il ne
/// quitte la mémoire du processus que pour l'échange final. N'importe quelle
/// application du Mac peut enregistrer le scheme `notitime://` et capter le
/// `code` ; sans le `verifier`, elle ne peut rien en faire.
@MainActor
final class OAuthFlow: NSObject {

    struct Callback {
        let code: String
        let state: String
    }

    enum FlowError: LocalizedError {
        case userCancelled
        case authorizationDenied(String)
        case malformedCallback
        case stateMismatch

        var errorDescription: String? {
            switch self {
            case .userCancelled:
                return "Connexion annulée."
            case .authorizationDenied(let reason):
                return "Notion a refusé l'autorisation (\(reason))."
            case .malformedCallback:
                return "La réponse de Notion est incomplète. Relancez la connexion."
            case .stateMismatch:
                // Cas anormal : une autre application a répondu à notre place.
                return "La réponse reçue ne correspond pas à la demande envoyée."
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    /// Lance le flux et rend le couple (code, verifier) prêt pour l'échange.
    func authorize() async throws -> (callback: Callback, verifier: String) {
        let verifier = OAuthFlow.makeVerifier()
        let state = OAuthFlow.state(for: verifier)
        let url = try OAuthFlow.authorizationURL(state: state)

        // La boîte d'autorisation s'ancre à la fenêtre de configuration : on lui
        // laisse le temps de paraître quand la connexion part du menu.
        await AppWindows.settle()
        let callbackURL = try await present(url)
        let callback = try OAuthFlow.parse(callbackURL)

        guard callback.state == state else { throw FlowError.stateMismatch }
        return (callback, verifier)
    }

    // MARK: - Construction

    /// 32 octets aléatoires en base64url, conformément au contrat.
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func state(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(state: String) throws -> URL {
        var components = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: try AppConfiguration.notionClientID()),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "owner", value: "user"),
            URLQueryItem(name: "redirect_uri",
                         value: try AppConfiguration.backendBaseURL()
                             .appendingPathComponent("api/notion/callback").absoluteString),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    static func parse(_ url: URL) throws -> Callback {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw FlowError.malformedCallback
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        if let error = value("error") {
            throw FlowError.authorizationDenied(error)
        }
        guard let code = value("code"), let state = value("state"),
              !code.isEmpty, !state.isEmpty else {
            throw FlowError.malformedCallback
        }
        return Callback(code: code, state: state)
    }

    // MARK: - Présentation

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: AppConfiguration.callbackScheme
            ) { callbackURL, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? FlowError.userCancelled : error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: FlowError.malformedCallback)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            // L'utilisateur doit être connecté à Notion dans son navigateur :
            // une session éphémère l'obligerait à ressaisir ses identifiants.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }
}

extension OAuthFlow: ASWebAuthenticationPresentationContextProviding {

    /// Ancre de la demande d'autorisation.
    ///
    /// Une de nos fenêtres d'abord — accueil ou configuration — et non
    /// simplement « la fenêtre active » : quand la connexion part du menu,
    /// la fenêtre active est le
    /// popover, qui se ferme au premier clic ailleurs — la boîte se retrouvait
    /// attachée à une fenêtre en train de disparaître. Le repli créait une
    /// `NSWindow` jamais affichée, sans position ni taille : macOS plaçait
    /// alors la boîte au petit bonheur, flottant par-dessus le reste.
    ///
    /// La position exacte reste au système : cette boîte est présentée par
    /// `AuthenticationServices`, pas par nous, et rien d'exposé ne permet de la
    /// déplacer. L'ancre décide de la fenêtre à laquelle elle s'attache, pas de
    /// l'endroit où elle s'y pose.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchor = AppWindows.anchor() { return anchor }
        if let key = NSApp.keyWindow, key.isVisible, key.canBecomeMain { return key }
        if let main = NSApp.mainWindow { return main }
        // Dernier recours : une fenêtre centrée, pour que la boîte ne se pose
        // pas dans un coin de l'écran.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.center()
        return window
    }
}
