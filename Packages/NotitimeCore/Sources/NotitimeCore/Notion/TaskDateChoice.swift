import Foundation

/// Choisit la date à montrer pour une tâche, parmi les propriétés de sa page.
///
/// Une base de tâches porte presque toujours plusieurs dates, dont deux que
/// Notion tient lui-même : création et dernière modification. Les afficher
/// n'apprendrait rien de ce qu'on vient chercher dans une liste de tâches —
/// l'échéance. Elles sont donc écartées par leur **type**, et aussi par leur
/// **nom** : une propriété *date* nommée « Date de création » est tenue à la
/// main, mais elle n'est pas davantage une échéance.
///
/// Aucun nom n'est imposé à l'utilisateur : on préfère celui qui annonce une
/// échéance, et à défaut la première date qui n'est pas du système.
public enum TaskDateChoice {

    /// Ce qui annonce une échéance, par ordre de préférence.
    static let preferred = ["deadline", "echeance", "date limite", "limite",
                            "due date", "due", "a rendre", "livraison"]

    /// Ce que Notion tient lui-même, ou ce qui le recopie à la main.
    static let excluded = ["created time", "created", "creation", "date de creation",
                           "cree le", "last edit", "last edited", "last edited time",
                           "derniere modification", "modifie le", "updated", "updated at"]

    /// La date retenue pour cette page, s'il y en a une.
    public static func date(in properties: [String: Any]) -> Date? {
        candidates(in: properties).first?.date
    }

    /// La propriété *date* où écrire une échéance, dans le schéma d'une base.
    ///
    /// Mêmes règles que pour la lecture : ni date du système — elles ne sont de
    /// toute façon pas inscriptibles —, ni date qui en porte le nom, et
    /// préférence à celle qui annonce une échéance.
    public static func writableProperty(in schema: [String: NotionPropertySchema]) -> String? {
        schema.values
            .compactMap { property -> (rank: Int, name: String)? in
                guard property.type == .date else { return nil }
                let folded = fold(property.name)
                guard !excluded.contains(where: { folded.contains($0) }) else { return nil }
                return (preferred.firstIndex { folded.contains($0) } ?? preferred.count,
                        property.name)
            }
            .sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
            .first?.name
    }

    struct Candidate {
        let name: String
        let date: Date
        /// Rang du nom dans `preferred`, ou le nombre d'entrées si absent.
        let rank: Int
    }

    /// Les dates retenues, la meilleure d'abord.
    static func candidates(in properties: [String: Any]) -> [Candidate] {
        var found: [Candidate] = []
        for (name, raw) in properties {
            guard let property = raw as? [String: Any],
                  // Le type écarte `created_time` et `last_edited_time`, que
                  // Notion remplit seul et qu'on ne peut pas confondre.
                  property["type"] as? String == "date",
                  let value = property["date"] as? [String: Any],
                  let start = value["start"] as? String,
                  let date = parse(start) else { continue }

            let folded = fold(name)
            guard !excluded.contains(where: { folded.contains($0) }) else { continue }
            let rank = preferred.firstIndex { folded.contains($0) } ?? preferred.count
            found.append(Candidate(name: name, date: date, rank: rank))
        }
        // À rang égal, l'ordre alphabétique : le bloc `properties` est un
        // dictionnaire, et sans départage la date affichée changerait d'une
        // lecture à l'autre pour la même tâche.
        return found.sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "fr_FR"))
    }

    /// `start` vaut « 2026-08-28 » ou « 2026-08-28T10:00:00.000+02:00 ».
    static func parse(_ start: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: start) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: start) { return date }

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone.current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: start)
    }
}
