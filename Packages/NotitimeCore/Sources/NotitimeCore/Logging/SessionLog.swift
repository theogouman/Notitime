import Foundation
import os

/// Journal local rotatif, borné, exportable depuis les réglages (FR-037).
///
/// Double sortie : `os.Logger` pour le diagnostic en direct dans la Console, et un
/// fichier en rotation pour l'export — `OSLogStore` ne convient pas, son accès
/// étant restreint pour un bundle non signé (R-13).
///
/// **Étanchéité.** Aucun token, aucun code OAuth, aucun `verifier`, et d'une tâche
/// seulement son identifiant. La rédaction n'est pas laissée à l'appelant : le
/// journal filtre lui-même ce qui ressemble à un secret.
public actor SessionLog {

    public enum Category: String, Sendable {
        case app, session, sync, auth, error
    }

    public static let maxFileBytes = 2 * 1024 * 1024
    public static let rotatedFileCount = 2

    private let directory: URL
    private let fileName: String
    private let logger = Logger(subsystem: "com.notitime.app", category: "notitime")
    private let time: TimeSource
    private let formatter: ISO8601DateFormatter

    public init(directory: URL, fileName: String = "notitime.log", time: TimeSource) {
        self.directory = directory
        self.fileName = fileName
        self.time = time
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        self.formatter = formatter
    }

    public var currentFileURL: URL { directory.appendingPathComponent(fileName) }

    public func log(_ category: Category, _ message: String) {
        let sanitized = SessionLog.redact(message)
        logger.log("[\(category.rawValue, privacy: .public)] \(sanitized, privacy: .public)")
        let line = "\(formatter.string(from: time.wallClock)) [\(category.rawValue)] \(sanitized)\n"
        append(line)
    }

    /// Contenu courant, pour l'export depuis les réglages.
    public func exportedContents() -> String {
        let files = (0..<SessionLog.rotatedFileCount).map { url(forIndex: $0) }.reversed()
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    // MARK: - Rédaction

    private static let secretKeys = ["token", "access_token", "refresh_token", "code",
                                     "verifier", "state", "authorization", "secret",
                                     "client_secret", "bearer"]

    /// Remplace la valeur de toute clé sensible par `***`.
    ///
    /// Volontairement large : mieux vaut masquer une valeur anodine que laisser
    /// fuir un token dans un fichier que l'utilisateur transmettra au support.
    static func redact(_ message: String) -> String {
        var output = message

        // L'ordre compte. « Authorization: Bearer <token> » traité d'abord par la
        // règle clé/valeur ne masquerait que le mot « Bearer » et laisserait le
        // token derrière lui — c'est exactement ce qu'un test a attrapé.
        output = replace(in: output,
                         pattern: "(?i)\\bBearer\\s+[^\\s\"',;)}\\]]+",
                         template: "Bearer ***")

        // Un en-tête d'autorisation est masqué jusqu'à la fin de la ligne : sa
        // valeur peut contenir des espaces, un masquage par jeton laisserait fuir.
        output = replace(in: output,
                         pattern: "(?im)(\\bauthorization\\b\\s*[=:]\\s*).*$",
                         template: "$1***")

        for key in secretKeys {
            output = replace(in: output,
                             pattern: "(?i)(\"\(key)\"\\s*:\\s*\")[^\"]*(\")",
                             template: "$1***$2")
            // Un entier — éventuellement signé — n'est jamais un secret, mais
            // c'est souvent un code de diagnostic : `Code=-999` pour une requête
            // annulée, `code=429` pour une limite de débit. Les masquer rendait
            // le journal inutilisable là où il sert le plus.
            output = replace(in: output,
                             pattern: "(?i)(\\b\(key)\\b\\s*[=:]\\s*)(?!-?\\d+\\b)[^\\s,;)}\\]]+",
                             template: "$1***")
        }
        return output
    }

    private static func replace(in input: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    // MARK: - Écriture et rotation

    private func url(forIndex index: Int) -> URL {
        index == 0 ? currentFileURL : directory.appendingPathComponent("\(fileName).\(index)")
    }

    private func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = currentFileURL

        if let size = try? manager.attributesOfItem(atPath: target.path)[.size] as? Int,
           size + line.utf8.count > SessionLog.maxFileBytes {
            rotate()
        }

        guard let data = line.data(using: .utf8) else { return }
        if manager.fileExists(atPath: target.path),
           let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: target)
        }
    }

    /// Décale les fichiers et supprime le plus ancien : le total reste borné.
    private func rotate() {
        let manager = FileManager.default
        let oldest = url(forIndex: SessionLog.rotatedFileCount - 1)
        try? manager.removeItem(at: oldest)
        for index in stride(from: SessionLog.rotatedFileCount - 2, through: 0, by: -1) {
            let source = url(forIndex: index)
            let destination = url(forIndex: index + 1)
            if manager.fileExists(atPath: source.path) {
                try? manager.removeItem(at: destination)
                try? manager.moveItem(at: source, to: destination)
            }
        }
    }
}
