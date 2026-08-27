# Contract: Surface publique de NotitimeCore

**Feature**: 001-notion-time-tracker | **Date**: 2026-08-27

`NotitimeCore` n'importe ni SwiftUI ni AppKit et n'ouvre aucune connexion réelle. Il expose sa logique et **quatre protocoles** que la cible applicative implémente avec les frameworks système. Cette frontière est ce qui rend les principes VI et VII applicables : les tests injectent des doublures et couvrent la logique sans machine réelle.

## Protocoles fournis par l'application

| Protocole | Implémentation applicative | Doublure de test |
|---|---|---|
| `HTTPTransport` | `URLSession` | Rejoue des fixtures JSON indexées par méthode et chemin |
| `TokenStore` | Keychain, `kSecClassGenericPassword` | Magasin en mémoire |
| `InactivityMonitor` | `CGEventSource.secondsSinceLastEventType` | Délai piloté par le test |
| `SleepObserver` | `NSWorkspace` willSleep / didWake | Événements émis à la demande |

À quoi s'ajoute une horloge injectable (`ContinuousClock` en production, horloge contrôlée en test) : sans elle, aucun scénario de durée n'est testable en CI.

## Composants exposés

| Composant | Responsabilité | Exigences couvertes |
|---|---|---|
| `SessionMachine` | Machine à états Pomodoro et Tracker, transitions, persistance à chaque pas, restauration au démarrage | FR-016 à FR-025 |
| `Outbox` | File durable, idempotence, backoff, classement des erreurs, réassignation | FR-026 à FR-031 |
| `NotionClient` | Appels de `contracts/notion-api.md`, rafraîchissement de token, classement des réponses | FR-001, FR-002, FR-029 |
| `SchemaValidator` | Validation d'une source contre le schéma attendu, liste des propriétés manquantes, proposition de création | FR-005, FR-006, FR-007 |
| `PropertyMapper` | Traduction clé logique ↔ propriété Notion, lecture et écriture des valeurs typées | FR-026, entité Configuration des bases |
| `TaskCache` | Rafraîchissement, pagination, filtres, recherche insensible casse/accents, tâches récentes | FR-009 à FR-014 |
| `RateLimiter` | Acteur unique, seau à 3 req/s, suspension globale sur `Retry-After` | FR-029 |
| `SessionLog` | Journal rotatif borné, filtrage des valeurs sensibles, export | FR-037 |

## Invariants garantis par Core, et donc testables sans interface

1. Une session éligible produit exactement une entrée de file (FR-026).
2. Aucune entrée ne quitte la file avant confirmation que la page existe (FR-027).
3. Aucun réessai d'issue indéterminée ne part sans vérification préalable par identifiant local, lu dans la propriété `rich_text` « ID » par défaut (FR-028).
4. Aucune vérification d'idempotence n'est émise en dehors de ce cas : ni à la première tentative, ni après une réponse d'erreur explicite de Notion (FR-028).
5. Aucune requête ne contourne le limiteur de débit (FR-029).
6. Aucune ligne de journal ne contient de token, de code OAuth ou de contenu de tâche au-delà de son identifiant (FR-037).
7. Aucun démarrage de session n'est possible sans tâche sélectionnée (FR-015).
