import Foundation

/// Configuration de déploiement, lue depuis l'Info.plist.
///
/// Le `client_id` OAuth n'est pas un secret — contrairement au `client_secret`,
/// qui ne quitte jamais l'environnement Vercel (principe III). Il est néanmoins
/// propre à l'installation Notion de l'éditeur : il n'est pas codé en dur ici.
enum AppConfiguration {

    enum ConfigurationError: LocalizedError {
        case missingClientID
        case invalidBackendURL

        var errorDescription: String? {
            switch self {
            case .missingClientID:
                return "NotionClientID est vide dans Info.plist. Renseignez l'identifiant "
                     + "public de l'intégration Notion avant de lancer la connexion."
            case .invalidBackendURL:
                return "BackendBaseURL est absent ou invalide dans Info.plist."
            }
        }
    }

    static func notionClientID() throws -> String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "NotionClientID") as? String) ?? ""
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigurationError.missingClientID
        }
        return value
    }

    static func backendBaseURL() throws -> URL {
        let value = (Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String) ?? ""
        guard let url = URL(string: value), url.scheme == "https" else {
            throw ConfigurationError.invalidBackendURL
        }
        return url
    }

    /// Scheme du callback, aligné sur `CFBundleURLTypes` et sur la variable
    /// `APP_CALLBACK_SCHEME` du backend.
    static let callbackScheme = "notitime"
    static let callbackHost = "auth"
}
