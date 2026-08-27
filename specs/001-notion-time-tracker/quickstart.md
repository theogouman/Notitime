# Phase 1 — Guide de validation

**Feature**: 001-notion-time-tracker | **Date**: 2026-08-27

Comment construire, tester et valider la feature de bout en bout, entièrement en ligne de commande (principe VI). Ce guide décrit ce qu'on lance et ce qu'on doit observer ; il ne contient pas de code d'implémentation.

## Prérequis

| Outil | Rôle |
|---|---|
| macOS 14+, Xcode 15.3+ (Swift 5.10) | Compilation et `xcodebuild` |
| `xcodegen` | Génération du `.xcodeproj` depuis `project.yml` |
| Node 20+ et `vercel` CLI | Fonctions serverless de `backend/` |
| Un workspace Notion de test | Validation manuelle du flux complet |

Aucun compte de développeur Apple n'est nécessaire : la v1 se distribue non signée.

## Boucle de développement

```bash
scripts/generate.sh     # xcodegen — à relancer après toute modification de project.yml
scripts/test.sh         # swift test sur NotitimeCore + xcodebuild test sur le schéma app
scripts/build.sh        # binaire universel arm64 + x86_64
scripts/package.sh      # produit Notitime.app
```

`.xcodeproj` est généré et ignoré par git : ne jamais l'éditer, ne jamais le commiter. La suite de tests doit passer sans réseau — si un test échoue en mode avion, c'est un défaut du test, pas de l'environnement.

## Validation automatisée — ce que la suite doit prouver

Tests exécutés par `swift test` sur `NotitimeCore`, sans réseau ni interface. Chaque ligne correspond à un scénario de la spec.

| Ce qui est vérifié | Comment | Spec |
|---|---|---|
| Un pomodoro arrivé à zéro produit une entrée « Complété » de la durée cible | Horloge contrôlée avancée jusqu'au terme | US2.2 |
| Un pomodoro arrêté à 4 min sur 25 produit une entrée « Écourté » de 4 min et remet la série à zéro | Horloge + événement `arrêter(utilisateur)` | US5.1, FR-020 |
| Une veille pendant un pomodoro clôture en « Écourté » daté de l'instant de la veille | `SleepObserver` simulé | US5.3 |
| Une veille pendant un tracker met en pause sans clôturer | `SleepObserver` simulé | US4.4 |
| Les pauses d'un tracker sont exclues de la durée | Séquence pause/reprise sur horloge contrôlée | US4.2, FR-021 |
| Une session de moins de 60 s ne produit aucune entrée | Horloge avancée de 59 s | FR-023 |
| L'inactivité retranchée réduit la durée sans changer « Complété » ni la série | `InactivityMonitor` simulé | US5.5, FR-020, FR-024 |
| Une session retrouvée après arrêt inopiné suit la règle de son mode | Magasin pré-rempli, `SessionMachine` redémarrée | US5.6 |
| Une entrée reste en file tant que la page n'est pas confirmée | Transport rejouant un `5xx` puis un `2xx` | FR-027 |
| Un réessai après réponse perdue ne crée pas de doublon | Fixture d'issue indéterminée, puis vérification par `localID` | FR-028, US6.4 |
| Un réessai après erreur explicite ne déclenche pas de vérification | Fixture `400` ; on compte les requêtes émises | FR-028, R-06 |
| Un `429` suspend le seau entier pour la durée de `Retry-After` | Fixture `429` + horloge | FR-029, US6.3 |
| Aucune requête ne dépasse 3 req/s | Compteur d'appels du transport de test | FR-029 |
| Une erreur permanente marque l'échec définitif sans réessai | Fixtures `400`, `403`, `404` | FR-029, FR-030 |
| Une base sans propriété requise est refusée avec la liste des manquantes | Fixture de schéma incomplet | US1.3, FR-006 |
| La découverte par schéma assigne les rôles après duplication du template | Fixtures de page dupliquée | US1.1, FR-004 |
| La recherche est insensible à la casse et aux accents et n'émet aucune requête | Cache pré-rempli, transport qui échoue sur tout appel | US3.4, FR-013 |
| Les tâches terminées sont exclues selon la configuration | Fixtures de statuts variés | FR-010 |
| Le journal ne contient jamais de token, de code ni de titre de tâche | Scénario complet puis inspection du fichier | FR-037 |

Les fonctions serverless ont leur propre suite dans `backend/tests/`, couvrant les cinq cas du contrat OAuth : `invalid_verifier`, annulation utilisateur, appel sans paramètre, échange nominal, relais d'un `invalid_grant`.

## Validation manuelle — le chemin qu'aucun test ne couvre

À faire une fois sur un workspace de test avant de considérer la feature livrée.

1. **Connexion par duplication du template.** Lancer l'app non connectée, dupliquer le template. Attendu : les trois bases reconnues sans saisie, nom d'utilisateur et de workspace affichés (US1.1, SC-001 : moins de 3 minutes).
2. **Connexion par pages existantes.** Sur un second compte du même workspace, partager la page dupliquée. Attendu : configuration valide sans saisir aucun identifiant (SC-007).
3. **Boucle de valeur.** Démarrer un pomodoro d'une minute sur une tâche. Attendu : compte à rebours dans la barre de menus, notification et son à la fin, entrée correctement remplie et reliée visible dans Notion en moins de 10 s (US2, SC-003).
4. **Écourtement.** Démarrer un pomodoro de 10 min, arrêter à 4 min. Attendu : entrée de 4 min au statut « Écourté », commentaire « arrêt par l'utilisateur » sur la page (US5.1).
5. **Veille réelle.** Démarrer un tracker, rabattre l'écran, rouvrir. Attendu : session en pause, aucune minute de veille comptée (US4.4).
6. **Dégradé réseau.** Couper le Wi-Fi, terminer deux sessions, rétablir. Attendu : « 2 entrées en attente » dans le menu, puis les deux entrées arrivent dans l'ordre, une seule fois chacune, indicateur revenu à zéro (US6, SC-004).
7. **États du menu.** Ouvrir le menu pendant le premier chargement, puis avec un filtre sans résultat, puis Wi-Fi coupé. Attendu : indicateur de progression, message distinguant le filtre trop restrictif, puis cache utilisable avec l'heure de dernière synchronisation (FR-015a).
8. **Repos.** Laisser l'app ouverte sans session pendant 30 min en observant le trafic réseau. Attendu : rien d'autre que le rafraîchissement périodique des tâches (SC-006).

## Déploiement du backend

```bash
cd backend
vercel env pull          # récupère .env.local, ignoré par git
npm test                 # suite locale contre un Notion simulé
vercel deploy --prod
```

Les quatre variables du contrat OAuth doivent être définies et chiffrées côté Vercel. `NOTION_REDIRECT_URI` doit être identique caractère pour caractère à l'URI déclarée dans le portail Notion — c'est la cause d'échec la plus fréquente du flux.

## Critère de sortie

La feature est prête pour `converge` quand la suite de tests passe sans réseau, que les huit validations manuelles sont observées, et qu'aucun warning Swift n'est produit par `scripts/build.sh`.
