# Contract: Surface de l'API Notion consommée

**Feature**: 001-notion-time-tracker | **Date**: 2026-08-27

Liste close des appels que `NotitimeCore` adresse à Notion. Tout appel hors de cette liste est un dépassement de périmètre à justifier.

**Version d'API : `2026-03-11`**, épinglée dans une constante unique (R-01). Le client est écrit contre le modèle **source de données** : une base est un conteneur pouvant porter plusieurs sources, et c'est la source qui porte le schéma, qui s'interroge et qui reçoit les pages. L'identifiant visible dans l'URL d'une base est celui du conteneur et n'est pas interrogeable. Conséquence transverse : **aucun appel de ce contrat ne prend un `database_id` en dehors de la résolution des sources**.

## Règles communes

- `Notion-Version` provient d'une constante unique. Aucun appel ne la surcharge.
- `Authorization: Bearer <access_token>` lu au Keychain juste avant l'appel, jamais mis en cache ailleurs, jamais journalisé.
- **Toute** requête traverse le limiteur à 3 req/s (R-05), y compris les vérifications d'idempotence et les commentaires.
- Un `401` déclenche un rafraîchissement de token via `POST /api/notion/refresh` du backend, puis un unique rejeu. Un second `401` déconnecte sans vider la file (FR-002, contrat OAuth).

## Appels en lecture

| Rôle | Appel | Quand | Exigences |
|---|---|---|---|
| Lister les sources accessibles | `POST /v1/search`, `filter: { "property": "object", "value": "data_source" }` | Configuration sans template dupliqué. Retourne des objets `data_source`, chacun portant `parent.database_id` | FR-005 |
| Lire les enfants d'une page | `GET /v1/blocks/{page_id}/children` | Découverte après duplication du template : on y relève les blocs `child_database` | FR-004, R-15 |
| Résoudre les sources d'une base | `GET /v1/databases/{database_id}` → `data_sources[]` (`id`, `name`) | Après découverte, et à chaque revalidation d'un rôle | FR-004, FR-007 |
| Lire le schéma d'une source | `GET /v1/data_sources/{data_source_id}` → `properties` | Validation, à chaque assignation ou changement | FR-006, FR-007 |
| Interroger une source | `POST /v1/data_sources/{data_source_id}/query` | Rafraîchissement des tâches et des projets | FR-009 |
| Interroger Time Entries par `localID` | `POST /v1/data_sources/{data_source_id}/query` filtré sur la propriété Identifiant local | **Uniquement** avant un réessai d'issue indéterminée | FR-028, R-06 |

Le filtre de l'interrogation des tâches porte le statut non terminé et, quand la propriété Personne est mappée, l'utilisateur courant — poussés côté API et non appliqués après coup (FR-009). La pagination se suit par `start_cursor` / `page_size` en requête et `has_more` / `next_cursor` en réponse, jusqu'à épuisement, sans plafond.

Les éléments dont `in_trash` est vrai sont exclus. Ce champ s'appelait `archived` avant `2026-03-11`, où il a été renommé sur les pages, bases, blocs et sources ; `archived` subsiste comme alias déprécié et ne doit pas être utilisé.

## Appels en écriture

| Rôle | Appel | Quand | Exigences |
|---|---|---|---|
| Créer une page dans Time Entries | `POST /v1/pages`, `parent: { "type": "data_source_id", "data_source_id": "..." }` | Envoi d'une entrée de la file | FR-026, FR-027 |
| Publier un commentaire | `POST /v1/comments`, `parent: { "page_id": "..." }` + `rich_text` | Session écourtée ou inactivité retranchée, **après** création réussie de la page | FR-026a |
| Ajouter une propriété manquante | `PATCH /v1/data_sources/{data_source_id}`, corps `properties` | Sur acceptation explicite de l'utilisateur, jamais automatiquement | FR-006 |

Pour la propriété de relation vers la tâche, une requête sous `2025-09-03` et au-delà doit ne contenir **que** `data_source_id` : fournir `database_id` est refusé, même si les réponses portent désormais les deux.

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

Le `403` couvre notamment l'absence de la capacité d'insertion de commentaires, que `POST /v1/comments` exige : dans ce cas l'entrée reste envoyée et seul le commentaire est abandonné (FR-026a).

Une réponse d'erreur explicite prouve qu'aucune page n'a été créée : le réessai correspondant se dispense de la vérification d'idempotence (R-06). Une absence de réponse ne prouve rien : `attemptOutcome` reste `indéterminée` et la vérification s'impose.
