# Notitime Constitution

## Core Principles

### I. Native, résident, léger
Notitime est une application macOS native (Swift, SwiftUI) qui vit dans la barre de menus. Un clic sur l'icône ouvre un menu compact ; il n'y a pas de fenêtre principale permanente. L'application doit rester imperceptible au repos : pas de polling agressif, pas de processus annexes, pas de dépendances tierces sauf justification écrite dans le plan. L'API Notion est consommée directement avec les frameworks système.

### II. Notion est la source de vérité
Toute donnée métier persistante (projets, tâches, entrées de temps) vit dans Notion. L'application ne crée aucun format de données propriétaire et n'a aucune base distante. Le stockage local sert exclusivement de cache de lecture, d'état de session en cours et de file d'envoi. L'analyse du temps se fait dans Notion (rollups, vues, graphiques), jamais dans l'application.

### III. Zéro donnée utilisateur côté serveur
Le seul composant serveur autorisé est un service sans état dont l'unique rôle est de porter le secret OAuth Notion (échange du code et rafraîchissement du token). Il ne journalise ni ne stocke aucun token, identifiant ou donnée utilisateur. Les tokens vivent dans le Keychain de l'utilisateur. Les identifiants de workspace, de bot et d'utilisateur retournés par Notion sont conservés localement pour usage futur (v2 licence par workspace) mais jamais transmis ailleurs qu'à Notion.

### IV. Une session ne se perd jamais
Une session de travail démarrée doit produire son entrée Notion, quelles que soient les conditions : coupure réseau, crash, fermeture de l'app, mise en veille, rate limit Notion. L'état de session est persisté localement à chaque transition. Les envois vers Notion passent par une file durable avec reprise automatique et sont idempotents : un rejeu ne crée jamais de doublon.

### V. Simplicité (YAGNI)
Chaque fonctionnalité doit servir l'un des deux usages fondateurs : démarrer une session sur une tâche Notion, envoyer le temps passé dans Notion. Pas de statistiques in-app, pas de concept d'équipe, pas de multi-workspace, pas de gestion de tâches (création, édition) en v1. Toute complexité ajoutée est justifiée dans le plan face à une alternative plus simple.

### VI. Pilotable par un agent
Le projet doit se construire, se tester et se packager entièrement en ligne de commande, sans ouvrir Xcode. Le projet Xcode est généré depuis une description texte (XcodeGen) versionnée ; le fichier `.xcodeproj` n'est pas édité à la main. La logique métier (machine à états du timer, file d'envoi, mapping des propriétés Notion, validation de schéma) est isolée dans un package Swift testable sans interface et sans réseau.

### VII. Tests sur la logique, pas sur les pixels
La machine à états des sessions, la file d'envoi et le mapping Notion sont couverts par des tests unitaires XCTest exécutés en CLI. Le client Notion est testé contre des réponses enregistrées, jamais contre l'API réelle en CI. L'interface SwiftUI n'a pas de tests automatisés obligatoires. Un build qui casse un test ne se merge pas.

## Technical Constraints

- Cible : macOS 14 (Sonoma) et supérieur, Apple Silicon et Intel.
- Langage : Swift 5.10 minimum, SwiftUI, `MenuBarExtra`. Concurrence via `async/await`.
- Persistance locale : SwiftData ou SQLite, au choix du plan ; aucun fichier de données lisible en clair contenant un token.
- Secrets : tokens Notion exclusivement dans le Keychain. Le client secret OAuth n'existe que dans l'environnement du service serveur.
- API Notion : en-tête `Notion-Version` figé dans une constante unique ; respect du rate limit (≈3 req/s) par un limiteur côté client ; gestion explicite des réponses 429 avec `Retry-After`.
- Authentification : OAuth 2.0 Notion (connexion publique) uniquement. Aucun token interne, aucun PAT en production.
- Service serveur : fonctions sans état, hébergement choisi dans le plan (gratuité et autorisation d'usage commercial requises).
- Distribution v1 : bundle `.app` non signé, installation manuelle par l'équipe. Signature Developer ID et notarisation reportées ; l'architecture ne doit rien faire qui les compliquerait (pas de sandbox contournée, entitlements minimaux).
- Langue : interface en français par défaut, chaînes externalisées pour permettre l'anglais.
- Vie privée : détection d'inactivité basée uniquement sur le temps depuis le dernier événement système ; aucun enregistrement de frappe, d'écran ou d'applications utilisées.

## Development Workflow

- Cycle spec-kit : `constitution` → `specify` → `clarify` → `plan` → `tasks` → `implement` → `converge`, une feature par spec, numérotation séquentielle.
- Chaque feature est développée sur sa branche, mergée quand `converge` rapporte Converged et que la suite de tests passe.
- Commits conventionnels (`feat:`, `fix:`, `chore:`…). Le build ne doit produire aucun warning Swift.
- Toute modification du schéma attendu des bases Notion (propriétés requises, types) est documentée dans `docs/notion-schema.md` et accompagnée d'une migration côté app (proposition de création des propriétés manquantes).
- Les changements de comportement visibles par l'utilisateur sont notés dans `CHANGELOG.md`.

## Governance

Cette constitution prévaut sur toute autre pratique du projet. Le plan de chaque feature contient une section Constitution Check qui vérifie explicitement les principes I à VII ; un écart doit être justifié par écrit dans le plan et accepté avant `tasks`. Les amendements sont versionnés en sémantique (MAJOR pour un retrait ou une redéfinition de principe, MINOR pour un ajout, PATCH pour une clarification) avec date et motif.

**Version**: 1.0.0 | **Ratified**: 2026-08-27 | **Last Amended**: 2026-08-27
