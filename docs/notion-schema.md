# Schéma Notion attendu

Ce document fait foi pour la validation de schéma (FR-006) et pour la proposition
de création des propriétés manquantes. Toute modification ici doit s'accompagner
d'une mise à jour de `SchemaDefinition.swift` et d'une migration côté application
— c'est une exigence du workflow de la constitution.

## Bases et sources de données

Depuis la version d'API `2025-09-03`, une **base** Notion est un conteneur qui
peut porter plusieurs **sources de données**. C'est la source qui détient le
schéma de propriétés, qui est interrogée et qui reçoit les pages créées.
L'identifiant visible dans l'URL d'une base est celui du conteneur : il ne suffit
pas à interroger quoi que ce soit.

Notitime lie donc chaque rôle à une **source**, en conservant l'identifiant de la
base pour l'affichage, l'ouverture dans Notion et la re-résolution. Quand une base
porte plusieurs sources, l'application demande laquelle utiliser plutôt que d'en
choisir une ou d'échouer (FR-006a).

Version d'API épinglée : **`2026-03-11`**, dans la constante unique
`NotionAPI.version`.

## Reconnaissance des bases

L'assignation des rôles se fait **par validation de schéma, jamais par le titre**.
Les titres sont traduisibles et renommables ; le schéma l'est beaucoup moins.
C'est ce qui permet à un second membre de l'équipe de partager la page du template
existant et d'obtenir une configuration valide sans saisir aucun identifiant
(SC-007), et à l'équipe de renommer une base sans rien casser.

Les trois bases peuvent être imbriquées dans la page parente — colonnes, bascule, encart, **sous-page** : la découverte traverse ces conteneurs jusqu'à cinq niveaux. Le template diffusé range précisément ses bases dans une sous-page « Template ». La descente ne s'arrête qu'aux bases elles-mêmes, dont les enfants sont des lignes et non des blocs.

Le rôle le plus contraint est attribué en premier. Une source Time Entries
satisferait aussi le schéma « Tâches » — un titre et un select suffisent — donc
l'ordre d'attribution est : Time Entries, puis Tâches, puis Projets.

Cet ordre ne suffit pas seul : dans le template diffusé, la base Projets remplit
aussi le schéma Tâches (un titre, un statut, une relation). Entre deux sources
valides pour un même rôle, celle qui le satisfait **le plus complètement**
l'emporte — le nombre de propriétés du rôle qu'elle sait fournir. L'utilisateur
n'est sollicité qu'à égalité stricte, là où il y a vraiment de quoi hésiter.

### Correspondance des noms de propriétés

La reconnaissance filtre d'abord **par type**. Le nom ne sert qu'à départager
plusieurs propriétés du même type, dans cet ordre :

1. nom exact ;
2. nom exact, casse et accents ignorés ;
3. **fragment de nom** parmi une liste d'indices — « Date de début » répond à
   `début`, « Status » à `status` ;
4. candidat unique du bon type ;
5. candidat unique du type **le plus attendu** — un `status` l'emporte sur un
   `select` pour un statut.

Chercher un fragment plutôt qu'un nom exact est ce qui permet de reconnaître le
template diffusé, dont les propriétés s'appellent « Name », « Status »,
« Date de début », « Date de fin », « Durée en min », « Méthode » et
« Responsable ». La colonne « Nom par défaut » des tableaux ci-dessous reste le
nom **créé** par l'application quand elle ajoute une propriété manquante ; ce
n'est pas une condition de reconnaissance.

## Rôle Tâches — lu seulement

L'application ne crée, ne modifie ni ne clôture aucune tâche.

| Clé logique | Nom par défaut | Type Notion accepté | Requis | Usage |
|---|---|---|---|---|
| `taskTitle` | Nom | `title` | oui | FR-012, FR-013 |
| `taskStatus` | Statut | `status` ou `select` | oui | FR-010 |
| `taskAssignee` | Personne | `people` | non | FR-011 |
| `taskProject` | Projet | `relation` → Projets | non | FR-012 |

Sans propriété Personne mappée, toutes les tâches non terminées sont proposées
(US3.2). Les valeurs de statut considérées comme terminées sont configurables ;
par défaut `Done`, `Terminé`, `Fait`.

## Rôle Time Entries — écrit

Dans le template fourni, cette base s'intitule **Time Tracker**. Le titre n'entre
pas dans la reconnaissance : seul le schéma compte.

| Clé logique | Nom par défaut | Type Notion | Requis | Usage |
|---|---|---|---|---|
| `entryTitle` | Nom | `title` | oui | Titre généré |
| `entryTask` | Tâche | `relation` → Tâches | oui | FR-026 |
| `entryStart` | Début | `date` | oui | UTC |
| `entryEnd` | Fin | `date` | oui | UTC |
| `entryDuration` | Durée | `number` | oui | Minutes entières |
| `entryType` | Type | `select` | oui | `Pomodoro`, `Tracker` |
| `entryStatus` | Statut | `status` ou `select` | oui | `Complété`, `Écourté` |
| `entryPerson` | Personne | `people` | oui | Utilisateur courant |
| `entryLocalID` | **ID** | **`rich_text`** | oui | Idempotence (FR-028) |

### Pourquoi `ID` doit être un texte, et rien d'autre

La valeur est **générée par l'application avant l'envoi** : c'est ce qui permet de
vérifier, avant un réessai d'issue indéterminée, qu'une entrée portant le même
identifiant n'existe pas déjà.

Ni une **formule** ni l'**identifiant unique auto-incrémenté** de Notion ne
peuvent tenir ce rôle : leur valeur n'existe qu'après la création de la page,
c'est-à-dire trop tard pour servir de clé de déduplication. Une base dont la
propriété d'identifiant est de type `unique_id` est donc refusée par la
validation, avec proposition de créer une propriété `rich_text`.

### Titre généré

`<Titre de la tâche> — <durée> min — <date et heure de début>`, tronqué à 200
caractères sur le titre de la tâche. Exemple : `Refonte facturation — 25 min —
27/08/2026 14:30`.

## Rôle Projets — optionnel, lu seulement

| Clé logique | Nom par défaut | Type Notion | Requis |
|---|---|---|---|
| `projectTitle` | Nom | `title` | oui |

## Rollups du template

Le template fournit des rollups (temps total par tâche, par projet) que
l'application **ne lit ni n'écrit**. Toute l'analyse du temps se fait dans Notion,
jamais dans l'application (principe II).

## Propriétés que l'application sait créer

Sur acceptation explicite de l'utilisateur, jamais automatiquement (FR-006), via
`PATCH /v1/data_sources/{id}`.

| Type | Créable | Remarque |
|---|---|---|
| `rich_text` | oui | dont la propriété `ID` |
| `date`, `people`, `number` | oui | |
| `select` | oui | les options `Type` et `Statut` sont créées avec leurs valeurs |
| `title` | non | toute base en possède déjà un |
| `relation` | non | la source cible ne peut pas être devinée : l'utilisateur la désigne |

## Capacités requises de l'intégration

Lire le contenu, insérer du contenu, mettre à jour le contenu (création des
propriétés manquantes), **insérer des commentaires** (motif d'écourtement,
FR-026a), lire les informations utilisateur sans email.
