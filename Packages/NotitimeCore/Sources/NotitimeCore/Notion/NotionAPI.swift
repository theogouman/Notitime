import Foundation

/// Surface de l'API Notion consommée par l'application.
///
/// La version est figée dans **une seule constante** (contrainte technique de la
/// constitution) : aucun appel ne la surcharge. Voir R-01 de `research.md` pour le
/// choix de `2026-03-11` et le passage au modèle « source de données ».
public enum NotionAPI {

    /// Valeur unique de l'en-tête `Notion-Version`. Ne jamais dupliquer.
    public static let version = "2026-03-11"

    public static let host = URL(string: "https://api.notion.com")!

    public enum Header {
        public static let version = "Notion-Version"
        public static let authorization = "Authorization"
        public static let contentType = "Content-Type"
        public static let retryAfter = "Retry-After"
    }

    /// Chemins des seuls appels autorisés par `contracts/notion-api.md`.
    ///
    /// Depuis `2025-09-03`, une base est un conteneur pouvant porter plusieurs
    /// sources de données : c'est la source qui porte le schéma, qui s'interroge
    /// et qui reçoit les pages. Aucun chemin ci-dessous ne prend un identifiant de
    /// base, hors `database` qui sert précisément à résoudre les sources.
    public enum Path {
        /// Résolution des sources d'une base : réponse portant `data_sources[]`.
        public static func database(_ databaseID: String) -> String {
            "/v1/databases/\(databaseID)"
        }

        /// Lecture du schéma (`properties`) et mise à jour de celui-ci.
        public static func dataSource(_ dataSourceID: String) -> String {
            "/v1/data_sources/\(dataSourceID)"
        }

        /// Interrogation d'une source de données.
        public static func queryDataSource(_ dataSourceID: String) -> String {
            "/v1/data_sources/\(dataSourceID)/query"
        }

        /// Modèles de page d'une source. C'est `is_default` qui désigne celui
        /// qu'applique `template[type]=default` à la création.
        public static func dataSourceTemplates(_ dataSourceID: String) -> String {
            "/v1/data_sources/\(dataSourceID)/templates"
        }

        /// Blocs enfants d'une page — découverte des `child_database` du template.
        public static func blockChildren(_ blockID: String) -> String {
            "/v1/blocks/\(blockID)/children"
        }

        public static let pages = "/v1/pages"
        public static let comments = "/v1/comments"
        public static let search = "/v1/search"
    }

    /// Nom par défaut de la propriété portant l'identifiant local d'idempotence.
    ///
    /// Type `rich_text` obligatoire : la valeur est générée par l'application
    /// *avant* l'envoi. Une formule ou l'identifiant auto-incrémenté de Notion ne
    /// peuvent pas tenir ce rôle, leur valeur n'existant qu'après création (FR-028).
    public static let defaultLocalIDPropertyName = "ID"
}
