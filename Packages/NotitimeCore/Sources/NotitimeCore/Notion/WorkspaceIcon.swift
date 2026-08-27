import Foundation

/// Ce que Notion range dans `workspace_icon` : une image, ou un emoji.
///
/// Les deux arrivent par le même champ, une simple chaîne. Convertir sans
/// discernement en `URL` perd les emoji — la majorité des workspaces —, et un
/// chemin relatif (`/icons/…`) ne se résout que contre le domaine de Notion.
public enum WorkspaceIcon: Sendable, Equatable {
    case image(URL)
    case emoji(String)
    case none

    /// Longueur au-delà de laquelle une chaîne n'est plus un emoji mais une
    /// adresse qu'on n'a pas su lire.
    private static let maximumEmojiLength = 8
    private static let notionHost = URL(string: "https://www.notion.so")!

    public static func parse(_ raw: String?) -> WorkspaceIcon {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return .none }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed).map(WorkspaceIcon.image) ?? .none
        }
        // Icône intégrée de Notion, servie depuis son domaine.
        if trimmed.hasPrefix("/") {
            return URL(string: trimmed, relativeTo: notionHost).map { .image($0.absoluteURL) } ?? .none
        }
        return trimmed.count <= maximumEmojiLength ? .emoji(trimmed) : .none
    }
}
