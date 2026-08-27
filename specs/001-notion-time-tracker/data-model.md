# Phase 1 — Modèle de données

**Feature**: 001-notion-time-tracker | **Date**: 2026-08-27

Deux modèles cohabitent : le **modèle local SwiftData**, qui n'est qu'un cache de lecture, un état de session et une file d'envoi (principe II), et le **schéma Notion**, seul dépositaire des données métier. La correspondance entre les deux passe par un mapping explicite, jamais par des noms de propriétés codés en dur.

---

## 1. Modèle local (SwiftData)

Magasin unique dans `Application Support/Notitime/`. **Aucun token n'y figure** : les tokens vivent au Keychain (R-07).

### `NotionConnection`

Une seule instance à la fois (FR-003, hypothèse mono-workspace).

| Champ | Type | Notes |
|---|---|---|
| `workspaceID` | `String` | Renvoyé par l'autorisation |
| `workspaceName` | `String` | Affichage |
| `workspaceIconURL` | `URL?` | Affichage |
| `botID` | `String` | |
| `ownerUserID` | `String` | Identifie l'utilisateur courant, sert au filtre Personne (FR-011) et au remplissage de la propriété Personne (FR-026) |
| `ownerName` | `String` | Affichage |
| `duplicatedTemplateID` | `String?` | Vide si l'utilisateur a choisi des pages existantes (FR-004/FR-005) |
| `connectedAt` | `Date` | |

### `DatabaseBinding`

Une instance par rôle : `tasks` (requis), `timeEntries` (requis), `projects` (optionnel).

| Champ | Type | Notes |
|---|---|---|
| `role` | `Role` | `.tasks` / `.timeEntries` / `.projects` |
| `databaseID` | `String` | Conteneur. C'est l'identifiant visible dans l'URL Notion, mais il n'est **pas** interrogeable (R-01) |
| `dataSourceID` | `String` | **L'unité réellement liée au rôle.** Porte le schéma, sert à interroger, à écrire et à créer les propriétés manquantes |
| `dataSourceName` | `String` | Distingue les sources quand la base en porte plusieurs |
| `title` | `String` | Titre de la base conteneur, affichage dans les réglages |
| `propertyMap` | `[PropertyKey: PropertyRef]` | Mapping logique → propriété réelle |
| `lastValidatedAt` | `Date?` | |
| `validationState` | `enum` | `.valid` / `.missingProperties([PropertyKey])` / `.invalid(reason)` |

`PropertyRef` retient `id`, `name` et `type` de la propriété Notion. L'`id` est stable au renommage : c'est lui qui sert aux requêtes, le `name` n'étant conservé que pour l'affichage et les messages de re-mapping.

**Règle de liaison (R-01).** Un rôle est toujours lié à une source de données, jamais à une base. Quand une base assignée expose plusieurs sources, l'application les présente avec leur `dataSourceName` et demande laquelle porte le rôle ; elle ne choisit pas d'office et n'échoue pas. `databaseID` n'est conservé que pour l'affichage, pour ouvrir la base dans Notion et pour re-résoudre les sources lors d'une revalidation. Toute requête — interrogation, création de page, ajout de propriété — passe par `dataSourceID`.

**Revalidation.** Si un `dataSourceID` mémorisé n'existe plus, l'application re-résout les sources de `databaseID` : s'il n'en reste qu'une, elle la propose ; s'il y en a plusieurs, elle redemande le choix ; s'il n'y en a aucune, la configuration passe en `.invalid`.

### `CachedTask` et `CachedProject`

Cache de lecture, reconstruit à chaque rafraîchissement (FR-009). Jamais écrit vers Notion (hypothèse : l'app ne modifie aucune tâche).

| `CachedTask` | Type | Notes |
|---|---|---|
| `pageID` | `String` | Clé |
| `title` | `String` | |
| `statusValue` | `String?` | Valeur brute, comparée aux valeurs terminées configurées (FR-010) |
| `assigneeIDs` | `[String]` | Vide = non assignée (FR-011, réglage tâches non assignées) |
| `projectPageID` | `String?` | |
| `searchKey` | `String` | Titre + nom de projet, minuscules et sans diacritiques, pré-calculé pour FR-013 |
| `lastSyncedAt` | `Date` | |

| `CachedProject` | Type |
|---|---|
| `pageID` | `String` |
| `title` | `String` |

### `RecentTaskUse`

Alimente la section « Récentes » (FR-014), indépendante du filtre courant.

| Champ | Type | Notes |
|---|---|---|
| `taskPageID` | `String` | |
| `lastUsedAt` | `Date` | Tri décroissant, 5 entrées retenues par défaut |

Une tâche récente devenue terminée est masquée sans être supprimée : elle disparaît de la liste, et réapparaît si son statut redevient ouvert.

### `ActiveSession`

Zéro ou une instance. **Réécrite à chaque transition** de la machine à états (FR-022) — c'est le mécanisme qui rend la reprise après arrêt inopiné possible (US5.6).

| Champ | Type | Notes |
|---|---|---|
| `localID` | `UUID` | Devient l'identifiant local de l'entrée de temps (FR-026, FR-028) |
| `taskPageID` | `String` | |
| `mode` | `.pomodoro` / `.tracker` | |
| `targetDuration` | `Duration?` | Pomodoro seulement |
| `startedAt` | `Date` | UTC |
| `state` | `.running` / `.paused` | |
| `pauseIntervals` | `[DateInterval]` | Tracker (FR-021) |
| `idleIntervals` | `[DateInterval]` | Inactivité détectée, pas encore arbitrée (FR-024) |
| `completedPomodoroStreak` | `Int` | Série consécutive, remise à zéro par un écourtement (FR-020) |
| `lastHeartbeatAt` | `Date` | Écrit à chaque transition et à chaque tick ; sert à dater la fin d'une session retrouvée après un arrêt inopiné |

### `OutboxEntry`

La file d'envoi durable (FR-027). Une entrée y est créée **avant** toute tentative réseau et n'en sort que sur création confirmée de la page.

| Champ | Type | Notes |
|---|---|---|
| `localID` | `UUID` | Identifiant local, écrit dans Notion pour l'idempotence (FR-028) |
| `taskPageID` | `String` | Réassignable en cas d'échec définitif (FR-031) |
| `title` | `String` | Titre généré, voir §3 |
| `startedAt` / `endedAt` | `Date` | UTC |
| `durationMinutes` | `Int` | Durée effective arrondie à la minute la plus proche |
| `type` | `.pomodoro` / `.tracker` | |
| `status` | `.completed` / `.shortened` | « Complété » / « Écourté » (FR-019, FR-026) |
| `shortenReason` | `.user` / `.sleep` / `.unexpectedQuit` / `nil` | Local ; publié en commentaire, pas en propriété (FR-026a) |
| `subtractedIdleMinutes` | `Int` | 0 si rien n'a été retranché ; mentionné dans le commentaire |
| `sendState` | `.pending` / `.failed(cause)` | Retirée de la file dès que la page existe |
| `attemptOutcome` | `.neverAttempted` / `.explicitError` / `.indeterminate` | Décide de la vérification d'idempotence au réessai (R-06) |
| `attemptCount` | `Int` | |
| `nextAttemptAt` | `Date?` | Backoff plafonné |
| `createdPageID` | `String?` | Renseigné à la création ; permet la publication du commentaire |
| `commentPosted` | `Bool` | Best-effort, n'empêche jamais le retrait de la file (FR-026a) |

### `AppSettings`

Instance unique (FR-007, FR-018, FR-024, FR-032, FR-033, FR-034, entité Réglages de la spec) : durées et préréglages Pomodoro, nombre de pomodoros avant pause longue, activation et seuil d'inactivité **par mode**, notifications, son, lancement à l'ouverture de session, raccourci de Concentration, intervalle de rafraîchissement, affichage des tâches non assignées, valeurs de statut considérées terminées.

---

## 2. Schéma Notion attendu

Reproduit dans `docs/notion-schema.md`, qui fait foi pour la validation (FR-006) et pour la proposition de création des propriétés manquantes.

### Base Tâches — lue seulement

| Clé logique | Type Notion | Requis | Usage |
|---|---|---|---|
| `title` | `title` | oui | FR-012, FR-013 |
| — | — | — | Les tâches à `in_trash` vrai sont exclues (champ renommé depuis `archived` en `2026-03-11`) |
| `status` | `status` ou `select` | oui | FR-010 |
| `assignee` | `people` | non | FR-011 |
| `project` | `relation` → Projets | non | FR-012 |

### Base Time Entries — écrite

| Clé logique | Type Notion | Requis | Usage |
|---|---|---|---|
| `title` | `title` | oui | Titre généré, §3 |
| `task` | `relation` → Tâches | oui | FR-026 |
| `start` | `date` | oui | UTC |
| `end` | `date` | oui | UTC |
| `duration` | `number` | oui | Minutes entières |
| `type` | `select` | oui | `Pomodoro`, `Tracker` |
| `status` | `select` | oui | `Complété`, `Écourté` |
| `person` | `people` | oui | Utilisateur courant ; omise si Notion la refuse pour un invité, avec information unique à l'utilisateur |
| `localID` | `rich_text` | oui | Identifiant local, support de l'idempotence (FR-028) |

### Base Projets — optionnelle, lue seulement

| Clé logique | Type Notion | Requis |
|---|---|---|
| `title` | `title` | oui |

Les rollups fournis par le template (temps total par tâche, par projet) ne sont ni lus ni écrits par l'application.

Le schéma est lu sur la **source**, jamais sur la base : `GET /v1/data_sources/{id}` renvoie le champ `properties` qui fait foi pour la validation (FR-006) et pour la proposition de création des propriétés manquantes, appliquée par `PATCH /v1/data_sources/{id}`.

---

## 3. Titre généré des entrées de temps

**Décision** : `<Titre de la tâche> — <durée> min — <date et heure de début, format court localisé>`, par exemple `Refonte facturation — 25 min — 27/08/2026 14:30`. Le titre est tronqué à 200 caractères, la troncature portant sur le titre de la tâche.

**Justification** : le titre est ce que l'utilisateur voit dans une vue liste Notion ; y placer d'abord la tâche rend la lecture utile même quand la colonne relation est masquée. Durée et heure lèvent l'ambiguïté entre plusieurs sessions du même jour sur la même tâche. Le format est une chaîne localisée, pas une concaténation codée en dur.

---

## 4. Machine à états des sessions

Une seule session active à la fois (FR-017). Les événements sont nommés et injectables : c'est ce qui rend l'ensemble testable sans machine réelle (principe VII).

### Mode Pomodoro

```
        démarrer(tâche, durée)
idle ─────────────────────────────> running
                                      │
              compte à rebours = 0    │  arrêter(utilisateur)
                     │                │  veille
                     v                │  reprise après arrêt inopiné
              allée à son terme       v
              statut « Complété »   écourtée, statut « Écourté »
                     │                │  + commentaire (motif)
                     └────────┬───────┘  + série remise à zéro
                              v
                      durée effective < 60 s ? ─ oui ─> ignorée, rien n'est envoyé (FR-023)
                              │ non
                              v
                     inactivité en attente d'arbitrage ? ─ oui ─> demander conserver/retrancher
                              │                                          │
                              └──────────────────┬───────────────────────┘
                                                 v
                                          mise en file (OutboxEntry)
                                                 │
                          allée à son terme ─────┴──> proposer pause (courte, ou longue tous les N)
```

Le mode Pomodoro n'offre pas de pause manuelle en cours de session (FR-018). Une pause proposée après coup ne génère jamais d'entrée (FR-020) et peut être interrompue pour repartir immédiatement.

### Mode Tracker

```
        démarrer(tâche)                 pause / veille
idle ────────────────────> running <──────────────────> paused
                              │                            │
                              │ arrêter                    │ arrêter
                              v                            v
                        durée effective = fin − début − pauses − inactivité retranchée
                              │
                              v
                        < 60 s ? ─ oui ─> ignorée (FR-023)
                              │ non
                              v
                        statut « Complété », mise en file
```

Une session Tracker retrouvée après un arrêt inopiné est présentée **en pause**, l'utilisateur choisissant de reprendre ou d'arrêter (US5.6) ; un Pomodoro retrouvé est clôturé d'office en « Écourté », daté du dernier `lastHeartbeatAt`.

### Règles invariantes, à couvrir par les tests

1. Une session éligible produit **exactement une** `OutboxEntry` (FR-026).
2. `durationMinutes` ne compte jamais une période de pause ni une période d'inactivité retranchée (FR-021, FR-024).
3. Une session de moins de 60 s ne produit aucune entrée, quel que soit le mode ou le résultat (FR-023).
4. Un écourtement remet `completedPomodoroStreak` à zéro ; un simple retranchement d'inactivité ne le fait pas (FR-020).
5. Aucune transition ne peut se produire sans que `ActiveSession` soit réécrite avant que le contrôle ne revienne (FR-022).
6. Le statut Notion se déduit uniquement du résultat de session ; `shortenReason` ne quitte jamais le commentaire (FR-026a).
