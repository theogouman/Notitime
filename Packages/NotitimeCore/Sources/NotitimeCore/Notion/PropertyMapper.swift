import Foundation

/// Traduction entre clés logiques et propriétés Notion réelles.
///
/// Les requêtes utilisent l'`id` de propriété, stable au renommage ; le `name`
/// n'est conservé que pour l'affichage et les messages de re-mapping. C'est ce
/// qui permet à l'équipe de renommer une colonne sans casser l'application.
public struct PropertyMapper: Sendable {

    public let map: [PropertyKey: PropertyRef]

    public init(map: [PropertyKey: PropertyRef]) {
        self.map = map
    }

    public func reference(_ key: PropertyKey) -> PropertyRef? { map[key] }
    public func name(_ key: PropertyKey) -> String? { map[key]?.name }

    // MARK: - Lecture d'une page

    /// Valeurs typées extraites du bloc `properties` d'une page Notion.
    public func readTitle(_ key: PropertyKey, from properties: [String: Any]) -> String? {
        guard let raw = value(key, in: properties),
              let items = raw["title"] as? [[String: Any]] else { return nil }
        let text = items.compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    public func readRichText(_ key: PropertyKey, from properties: [String: Any]) -> String? {
        guard let raw = value(key, in: properties),
              let items = raw["rich_text"] as? [[String: Any]] else { return nil }
        let text = items.compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// Accepte `status` comme `select` : la spec autorise les deux (FR-010).
    public func readStatusValue(_ key: PropertyKey, from properties: [String: Any]) -> String? {
        guard let raw = value(key, in: properties) else { return nil }
        for container in ["status", "select"] {
            if let object = raw[container] as? [String: Any], let name = object["name"] as? String {
                return name
            }
        }
        return nil
    }

    public func readPeopleIDs(_ key: PropertyKey, from properties: [String: Any]) -> [String] {
        guard let raw = value(key, in: properties),
              let people = raw["people"] as? [[String: Any]] else { return [] }
        return people.compactMap { $0["id"] as? String }
    }

    public func readRelationIDs(_ key: PropertyKey, from properties: [String: Any]) -> [String] {
        guard let raw = value(key, in: properties),
              let relations = raw["relation"] as? [[String: Any]] else { return [] }
        return relations.compactMap { $0["id"] as? String }
    }

    private func value(_ key: PropertyKey, in properties: [String: Any]) -> [String: Any]? {
        guard let reference = map[key] else { return nil }
        // Notion indexe le bloc `properties` par nom ; on retombe sur l'id quand
        // la propriété a été renommée entre deux rafraîchissements.
        if let byName = properties[reference.name] as? [String: Any] { return byName }
        for candidate in properties.values {
            if let object = candidate as? [String: Any], object["id"] as? String == reference.id {
                return object
            }
        }
        return nil
    }

    // MARK: - Écriture d'une page

    public func titleValue(_ key: PropertyKey, _ text: String) -> (String, [String: Any])? {
        guard let name = name(key) else { return nil }
        return (name, ["title": [["text": ["content": text]]]])
    }

    public func richTextValue(_ key: PropertyKey, _ text: String) -> (String, [String: Any])? {
        guard let name = name(key) else { return nil }
        return (name, ["rich_text": [["text": ["content": text]]]])
    }

    public func numberValue(_ key: PropertyKey, _ number: Int) -> (String, [String: Any])? {
        guard let name = name(key) else { return nil }
        return (name, ["number": number])
    }

    public func selectValue(_ key: PropertyKey, _ option: String) -> (String, [String: Any])? {
        guard let name = name(key) else { return nil }
        return (name, ["select": ["name": option]])
    }

    /// Écrit une valeur dans le conteneur qu'attend le **type réel** de la
    /// propriété.
    ///
    /// Un `status` et un `select` se ressemblent à la lecture mais pas à
    /// l'écriture : envoyer `{"select": …}` sur une propriété `status` produit
    /// un `400` de validation. Le template diffusé porte précisément un statut
    /// de type `status`, là où la documentation prévoyait un `select`.
    public func selectOrStatusValue(_ key: PropertyKey, _ option: String) -> (String, [String: Any])? {
        guard let reference = map[key] else { return nil }
        let container = reference.type == "status" ? "status" : "select"
        return (reference.name, [container: ["name": option]])
    }

    public func dateValue(_ key: PropertyKey, _ date: Date) -> (String, [String: Any])? {
        guard let name = name(key) else { return nil }
        return (name, ["date": ["start": PropertyMapper.iso8601.string(from: date)]])
    }

    public func peopleValue(_ key: PropertyKey, _ userIDs: [String]) -> (String, [String: Any])? {
        guard let name = name(key) else { return nil }
        return (name, ["people": userIDs.map { ["object": "user", "id": $0] }])
    }

    public func relationValue(_ key: PropertyKey, _ pageIDs: [String]) -> (String, [String: Any])? {
        guard let name = name(key) else { return nil }
        return (name, ["relation": pageIDs.map { ["id": $0] }])
    }

    /// Début et fin sont stockés en UTC (cas limite du changement d'horloge).
    public static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
