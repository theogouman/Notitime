# Contract: Surface de l'API Notion consommée

**Feature**: 001-notion-time-tracker | **Date**: 2026-08-27

Liste close des appels que `NotitimeCore` adresse à Notion. Tout appel hors de cette liste est un dépassement de périmètre à justifier. Les chemins exacts et la valeur de `Notion-Version` sont à confirmer contre la documentation en vigueur (R-01) ; ce contrat fige le **rôle** de chaque appel, ses conditions d'usage et le traitement de sa réponse.

## Règles communes

- `Notion-Version` provient d'une constante unique. Aucun appel ne la surcharge.
- `Authorization: Bearer <access_token>` lu au Keychain juste avant l'appel, jamais mis en cache ailleurs, jamais journalisé.
- **Toute** requête traverse le limiteur à 3 req/s (R-05), y compris les vérifications d'idempotence et les commentaires.
- Un `401` déclenche un rafraîchissement de token via `POST /api/notion/refresh` du backend, puis un unique rejeu. Un second `401` déconnecte sans vider la file (FR-002, contrat OAuth).

## Appels en lecture

| Rôle | Quand | Exigences |
|---|---|---|
| Lister les bases accessibles | Configuration sans template dupliqué | FR-005 |
| Lire les enfants d'une page | Découverte après duplication du template | FR-004, R-15 |
| Lire le schéma d'une source de données | Validation de schéma, à chaque assignation ou changement de base | FR-006, FR-007 |
| Interroger une source de données | Rafraîchissement des tâches et des projets, pagination suivie jusqu'au bout | FR-009 |
| Interroger Time Entries par `localID` | **Uniquement** avant un réessai d'issue indéterminée | FR-028, R-06 |

Le filtre de l'interrogation des tâches porte le statut non terminé et, quand la propriété Personne est mappée, l'utilisateur courant — poussés côté API et non appliqués après coup (FR-009).

## Appels en écriture

| Rôle | Quand | Exigences |
|---|---|---|
| Créer une page dans Time Entries | Envoi d'une entrée de la file | FR-026, FR-027 |
| Publier un commentaire sur la page créée | Session écourtée ou inactivité retranchée, après création réussie | FR-026a |
| Ajouter une propriété manquante à une source | Sur acceptation explicite de l'utilisateur, jamais automatiquement | FR-006 |

L'application n'écrit **jamais** dans la base Tâches ni dans la base Projets, et ne crée, modifie ni ne clôture aucune tâche.

## Classement des réponses (FR-029)

| Réponse | Classe | Conséquence |
|---|---|---|
| `2xx` | succès | Entrée retirée de la file dès que la page existe |
| `429` | transitoire | Suspend le seau entier pour la durée de `Retry-After`, puis réessai |
| `5xx`, erreur réseau, délai dépassé | transitoire | Réessai avec backoff plafonné, indéfiniment |
| `401` | particulière | Rafraîchissement puis un rejeu ; second échec = déconnexion, file conservée |
| `400` de validation | permanente | Échec définitif, cause affichée, action de résolution proposée |
| `403` permissions | permanente | Échec définitif |
| `404` base ou page introuvable | permanente | Échec définitif, réassignation de tâche possible (FR-031) |

Une réponse d'erreur explicite prouve qu'aucune page n'a été créée : le réessai correspondant se dispense de la vérification d'idempotence (R-06). Une absence de réponse ne prouve rien : `attemptOutcome` reste `indéterminée` et la vérification s'impose.
