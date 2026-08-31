---

description: "Task list for 001-notion-time-tracker"
---

# Tasks: Pomodoro & Time Tracker connecté à Notion

**Input**: Design documents from `/specs/001-notion-time-tracker/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: inclus et non optionnels. Le principe VII de la constitution impose une couverture XCTest de la machine à états, de la file d'envoi et du mapping Notion, et interdit d'appeler l'API réelle en CI. Les tâches de test précèdent l'implémentation qu'elles couvrent et doivent échouer avant elle.

**Organization**: une phase par user story, dans l'ordre de priorité de la spec. Chaque phase est indépendamment livrable et testable.

## Format: `[ID] [P?] [Story] Description`

- **[P]** : parallélisable (fichiers distincts, aucune dépendance sur une tâche incomplète)
- **[Story]** : user story couverte (US1 à US7)

## Path Conventions

Trois racines de code, conformément à la décision de structure de `plan.md` : `App/` (cible macOS), `Packages/NotitimeCore/` (logique métier testable), `backend/` (fonctions serverless). Le `.xcodeproj` est généré et jamais édité.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: rendre le dépôt constructible et testable en ligne de commande, sans ouvrir Xcode.

- [X] T001 Créer `project.yml` XcodeGen décrivant la cible app `Notitime` (bundle identifier `com.notitime.app`, macOS 14 minimum, arm64 + x86_64) et sa dépendance au package local
- [X] T002 Ajouter `Notitime.xcodeproj/` et `backend/.env.local` à `.gitignore`
- [X] T003 [P] Créer `Packages/NotitimeCore/Package.swift` (Swift 5.10, plateforme macOS 14, cible `NotitimeCore` + cible de tests, zéro dépendance externe)
- [X] T004 [P] Créer le squelette de la cible app dans `App/NotitimeApp.swift` avec `MenuBarExtra` et aucune fenêtre principale
- [X] T005 [P] Créer `App/Resources/Info.plist` déclarant `CFBundleURLTypes` avec le scheme `notitime` et `LSUIElement` à vrai
- [X] T006 [P] Créer `scripts/generate.sh`, `scripts/build.sh`, `scripts/test.sh`, `scripts/package.sh` conformément à la boucle décrite dans `quickstart.md`
- [X] T007 [P] Initialiser `backend/package.json`, `backend/vercel.json` et `backend/tests/` (Node 20, aucune dépendance à une API propriétaire de la plateforme — condition de l'écart accepté dans `plan.md`)
- [X] T008 [P] Créer `App/Resources/Localizable.xcstrings` vide et la convention d'accès aux chaînes, français par défaut (FR-036)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: les fondations sans lesquelles aucune user story n'est implémentable — frontière testable, persistance, limiteur, journal.

**⚠️ CRITIQUE** : aucune user story ne démarre avant la fin de cette phase.

- [X] T009 Créer `Packages/NotitimeCore/Sources/NotitimeCore/Notion/NotionAPI.swift` avec la constante unique `Notion-Version = "2026-03-11"` et les chemins d'endpoint de `contracts/notion-api.md` (R-01)
- [X] T010 [P] Définir les protocoles `HTTPTransport`, `TokenStore`, `InactivityMonitor`, `SleepObserver` dans `Packages/NotitimeCore/Sources/NotitimeCore/Support/SystemPorts.swift` (contrat `core-api.md`)
- [X] T011 [P] Définir l'horloge injectable dans `Packages/NotitimeCore/Sources/NotitimeCore/Support/Clock.swift` (`ContinuousClock` en production, horloge contrôlée en test — R-02)
- [X] T012 [P] Implémenter le chargeur de fixtures et le `HTTPTransport` de test dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/Support/FixtureTransport.swift`, indexé par méthode et chemin (R-09)
- [X] T013 [P] Implémenter les doublures `InMemoryTokenStore`, `StubInactivityMonitor`, `StubSleepObserver` dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/Support/`
- [X] T014 Implémenter l'acteur `RateLimiter` (seau à 3 jetons/seconde, suspension globale sur `Retry-After`) dans `Packages/NotitimeCore/Sources/NotitimeCore/Support/RateLimiter.swift` (FR-029, R-05)
- [X] T015 Écrire les tests du limiteur dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/RateLimiterTests.swift` : jamais plus de 3 requêtes par seconde, suspension globale sur `Retry-After`
- [X] T016 Créer les modèles SwiftData de `data-model.md` dans `Packages/NotitimeCore/Sources/NotitimeCore/Persistence/Models.swift` (`NotionConnection`, `DatabaseBinding`, `CachedTask`, `CachedProject`, `RecentTaskUse`, `ActiveSession`, `OutboxEntry`, `AppSettings`)
- [X] T017 Implémenter la construction du `ModelContainer` (fichier dans Application Support, variante en mémoire pour les tests) dans `Packages/NotitimeCore/Sources/NotitimeCore/Persistence/Store.swift` (R-08)
- [X] T018 [P] Implémenter le journal rotatif `SessionLog` (deux fichiers de 2 Mo, acteur dédié, filtrage des valeurs sensibles) dans `Packages/NotitimeCore/Sources/NotitimeCore/Logging/SessionLog.swift` (FR-037, R-13)
- [X] T019 [P] Écrire le test d'étanchéité du journal dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/SessionLogTests.swift` : aucun token, code OAuth ni titre de tâche, rotation effective au-delà du plafond
- [X] T020 [P] Implémenter `App/System/URLSessionTransport.swift` et `App/System/KeychainTokenStore.swift` (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`, service `com.notitime.app` — R-07)
- [X] T021 [P] Implémenter la garde d'instance unique via `NSRunningApplication` dans `App/NotitimeApp.swift` (FR-035, R-10)
- [X] T022 Définir le type de classement des réponses Notion (transitoire / permanente / `401`) dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/ResponseClass.swift` selon le tableau de `contracts/notion-api.md` (FR-029)

**Checkpoint**: fondations prêtes — les user stories peuvent démarrer.

---

## Phase 3: User Story 1 - Connecter Notion et configurer les bases (Priority: P1) 🎯 MVP

**Goal**: l'utilisateur connecte son workspace et obtient trois rôles liés à des sources de données valides, par duplication du template ou par assignation manuelle.

**Independent Test**: sur un workspace vierge, dupliquer le template via le flux OAuth et constater que les trois rôles sont reconnus sans saisie ; sur un second compte du même workspace, partager la page et constater la même reconnaissance ; sur une source à laquelle il manque une propriété, constater la proposition de création et sa réussite.

### Tests for User Story 1 ⚠️

- [X] T023 [P] [US1] Écrire les tests des trois routes serverless dans `backend/tests/` : `invalid_verifier`, annulation utilisateur, appel sans paramètre, échange nominal, relais d'un `invalid_grant` (cas de test du contrat OAuth)
- [X] T024 [P] [US1] Écrire les tests du validateur de schéma dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/SchemaValidatorTests.swift` avec fixtures de schéma valide et incomplet (US1.3, FR-006)
- [X] T025 [P] [US1] Écrire les tests de découverte des rôles dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/DiscoveryTests.swift` : page dupliquée → `child_database` → `data_sources[]` → assignation par schéma (US1.1, FR-004, R-15)
- [X] T026 [P] [US1] Écrire le test du cas base multi-sources dans `DiscoveryTests.swift` : plusieurs sources ⇒ demande de choix, jamais d'échec ni de choix d'office (FR-006a)
- [X] T027 [P] [US1] Écrire les tests de rafraîchissement et de révocation de token dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/AuthTests.swift` : `401` → refresh → un rejeu ; second `401` → déconnexion sans vider la file (US1.5, FR-002)

### Implementation for User Story 1

- [X] T028 [P] [US1] Implémenter `backend/api/notion/callback.js` : redirection vers `notitime://auth`, aucun appel Notion, aucun log de `code` ni `state`, `Cache-Control: no-store`
- [X] T029 [P] [US1] Implémenter `backend/api/notion/token.js` : vérification `base64url(sha256(verifier)) == state`, échange en Basic auth, relais tel quel du statut et du corps
- [X] T030 [P] [US1] Implémenter `backend/api/notion/refresh.js` : relais de l'échange `refresh_token`, remplacement du couple de tokens côté app
- [X] T031 [US1] Implémenter la génération `verifier`/`state` et le flux `ASWebAuthenticationSession` dans `App/Onboarding/OAuthFlow.swift` (`callbackURLScheme: "notitime"`, verifier jamais persisté — contrat OAuth, FR-001)
- [X] T032 [US1] Implémenter la persistance de la connexion (Keychain pour les tokens, `NotionConnection` pour le reste) dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/ConnectionService.swift` (FR-002, FR-003)
- [X] T033 [US1] Implémenter le rafraîchissement automatique et la déconnexion sur `invalid_grant` dans `ConnectionService.swift`, sans vider la file d'envoi (US1.5, FR-008)
- [X] T034 [US1] Implémenter `NotionClient` — appels de `contracts/notion-api.md`, passage systématique par le `RateLimiter`, classement des réponses — dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/NotionClient.swift`
- [X] T035 [US1] Implémenter la résolution des sources d'une base (`GET /v1/databases/{id}` → `data_sources[]`) dans `NotionClient.swift` (R-01)
- [X] T036 [US1] Implémenter `SchemaValidator` (lecture de `properties` sur la source, liste des propriétés manquantes) dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/SchemaValidator.swift` (FR-006)
- [X] T037 [US1] Implémenter la création des propriétés manquantes par `PATCH /v1/data_sources/{id}`, sur acceptation explicite uniquement, dans `SchemaValidator.swift` (FR-006)
- [X] T038 [US1] Implémenter `PropertyMapper` (clé logique ↔ propriété, lecture et écriture typées, `id` de propriété comme clé de requête) dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/PropertyMapper.swift`
- [X] T039 [US1] Implémenter la découverte après duplication du template dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/RoleDiscovery.swift` : assignation par schéma, jamais par titre (FR-004, R-15)
- [X] T040 [US1] Implémenter le listage des sources accessibles par `POST /v1/search` filtré sur `data_source` et la pré-sélection par schéma dans `RoleDiscovery.swift` (FR-005)
- [X] T041 [US1] Implémenter l'écran de connexion et d'assignation des rôles dans `App/Onboarding/` : liste des sources, choix de source pour une base multi-sources, propriétés manquantes et proposition de création (US1.2, US1.3, FR-006a)
- [X] T042 [US1] Implémenter l'affichage de l'état connecté (nom d'utilisateur, workspace, rôles liés) et la déconnexion avec avertissement si des entrées sont en attente dans `App/Onboarding/ConnectionStatusView.swift` (US1.1, FR-008)
- [X] T043 [US1] Implémenter la revalidation des rôles au démarrage de l'application — schéma de chaque source liée, routage vers l'écran de re-mapping en cas d'échec — dans `App/Onboarding/StartupValidation.swift` (cas limite « template modifié », FR-006, FR-007)
- [X] T044 [US1] Rédiger `docs/notion-schema.md` — schéma attendu des trois bases, conformément à `data-model.md` §2 (exigence du workflow de la constitution)

**Checkpoint**: la connexion et la configuration fonctionnent de bout en bout, indépendamment de toute session.

---

## Phase 4: User Story 2 - Lancer un Pomodoro et retrouver l'entrée dans Notion (Priority: P1)

**Goal**: la boucle de valeur complète — un pomodoro sur une tâche produit une entrée correcte dans Notion.

**Independent Test**: avec au moins une tâche, démarrer un pomodoro d'une minute, attendre la fin, vérifier dans Notion la présence d'une entrée correctement remplie et reliée.

### Tests for User Story 2 ⚠️

- [X] T045 [P] [US2] Écrire les tests de la machine à états Pomodoro dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/PomodoroMachineTests.swift` : arrivée à zéro ⇒ « Complété » de la durée cible ; une seule session active à la fois ; démarrage refusé sans tâche (US2.2, US2.5, US2.6, FR-015, FR-017)
- [X] T046 [P] [US2] Écrire le test de la règle des 60 secondes dans `PomodoroMachineTests.swift` : aucune entrée produite en deçà (FR-023)
- [X] T047 [P] [US2] Écrire les tests de la série et des pauses dans `PomodoroMachineTests.swift` : pause longue au N-ième pomodoro allé à son terme, aucune entrée pour une pause (US2.3, US2.4, FR-020)
- [X] T048 [P] [US2] Écrire les tests de composition d'une entrée dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/OutboxCompositionTests.swift` : les neuf propriétés de FR-026, `parent.data_source_id`, relation ne portant que `data_source_id`, titre généré au format de `data-model.md` §3
- [X] T049 [P] [US2] Écrire le test de persistance à chaque transition dans `PomodoroMachineTests.swift` : `ActiveSession` réécrite avant tout retour de contrôle (FR-022)

### Implementation for User Story 2

- [X] T050 [US2] Implémenter `SessionMachine` — états, événements nommés, horloge injectée, persistance à chaque transition — dans `Packages/NotitimeCore/Sources/NotitimeCore/Session/SessionMachine.swift` (FR-016 à FR-022)
- [X] T051 [US2] Implémenter le mode Pomodoro — compte à rebours, arrivée à terme, écourtement, série consécutive, absence de pause manuelle — dans `Packages/NotitimeCore/Sources/NotitimeCore/Session/PomodoroMode.swift` (FR-018, FR-019, FR-020)
- [X] T052 [US2] Implémenter la composition d'une `OutboxEntry` à partir d'une session éligible dans `Packages/NotitimeCore/Sources/NotitimeCore/Outbox/EntryComposer.swift` (FR-023, FR-026)
- [X] T053 [US2] Implémenter l'envoi d'une entrée — `POST /v1/pages` avec `parent.data_source_id`, retrait de la file sur confirmation seulement — dans `Packages/NotitimeCore/Sources/NotitimeCore/Outbox/Outbox.swift` (FR-027)
- [X] T054 [US2] Implémenter la publication du commentaire après création réussie, en best-effort, dans `Outbox.swift` : jamais de remise en file, `403` de capacité absente traité comme abandon du seul commentaire (FR-026a)
- [X] T055 [US2] Implémenter le chargement minimal des tâches — interrogation de la source liée au rôle Tâches, sans filtre Personne ni recherche, pagination simple — dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/TaskFetch.swift` (remplacé par `TaskCache` en US3)
- [X] T056 [US2] Implémenter la liste brute de sélection de tâche dans le menu — ni recherche, ni section « Récentes », ni filtre — dans `App/MenuBar/BasicTaskPicker.swift` (FR-015 ; remplacée par la liste confortable de l'US3)
- [X] T057 [US2] Implémenter l'affichage du compte à rebours et du nom court de la tâche dans la barre de menus dans `App/MenuBar/` (FR-025)
- [X] T058 [US2] Implémenter les notifications et le son de fin de pomodoro et de pause dans `App/System/NotificationPresenter.swift` (FR-032)
- [X] T059 [US2] Implémenter la proposition de pause après un pomodoro allé à son terme, et l'interruption de pause pour repartir immédiatement, dans `App/MenuBar/` (US2.2, cas limite pause longue)

**Checkpoint**: MVP démontrable de bout en bout — ouvrir le menu, choisir une tâche dans la liste brute, lancer un pomodoro, voir l'entrée arriver dans Notion. Les validations manuelles 1 à 4 de `quickstart.md` sont exécutables à ce stade.

---

## Phase 5: User Story 3 - Trouver sa tâche en quelques secondes (Priority: P2)

**Goal**: la sélection d'une tâche est immédiate, filtrée sur les tâches ouvertes de l'utilisateur, avec les récentes en tête.

**Independent Test**: avec 200 tâches dont 15 assignées, ouvrir le menu et constater que seules ces 15 non terminées apparaissent, que la recherche filtre en temps réel et que les récentes sont en tête.

### Tests for User Story 3 ⚠️

- [X] T060 [P] [US3] Écrire les tests du cache de tâches dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/TaskCacheTests.swift` : filtres poussés côté API, pagination suivie jusqu'à `has_more` faux, aucun plafond, exclusion des `in_trash` (FR-009)
- [X] T061 [P] [US3] Écrire les tests de filtrage par statut et par personne dans `TaskCacheTests.swift` : valeurs terminées configurées, tâches non assignées selon le réglage (US3.1 à US3.3, FR-010, FR-011)
- [X] T062 [P] [US3] Écrire le test de recherche dans `TaskCacheTests.swift` : insensible à la casse et aux accents, aucune requête réseau émise (US3.4, FR-013)
- [X] T063 [P] [US3] Écrire le test des tâches récentes dans `TaskCacheTests.swift` : en tête hors filtre courant, masquées si terminées (US3.5, FR-014)

### Implementation for User Story 3

- [X] T064 [US3] Implémenter `TaskCache` — interrogation paginée de la source, filtres côté API, mise en cache — dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/TaskCache.swift` (FR-009)
- [X] T065 [US3] Implémenter le calcul de `searchKey` (minuscules, sans diacritiques) et la recherche locale dans `TaskCache.swift` (FR-013)
- [X] T066 [US3] Implémenter les tâches récentes (`RecentTaskUse`, 5 par défaut, masquage des terminées) dans `TaskCache.swift` (FR-014)
- [X] T067 [US3] Implémenter le rafraîchissement périodique configurable et le rafraîchissement manuel, suspendus au repos, dans `TaskCache.swift` (FR-009, SC-006)
- [X] T068 [US3] Implémenter la liste de tâches du menu avec projet affiché et section « Récentes » dans `App/MenuBar/TaskList.swift` (FR-012, FR-014)
- [X] T069 [US3] Implémenter les états du menu — indicateur de premier chargement, liste vide qualifiée avec son action, Notion injoignable avec heure de dernière synchronisation réussie — dans `App/MenuBar/TaskListStates.swift` (FR-015a, US3.7 à US3.11)

- [X] T115 [US3] Remplacer le sélecteur et les deux boutons de lancement par un flux en accordéon dans le popover — la tâche se choisit dans la liste, la méthode s'ouvre sous son en-tête, la dernière méthode utilisée étant mise en avant et déclenchée par Entrée — dans `App/MenuBar/TaskLauncher.swift`, `TaskList.swift` et `SessionControls.swift` (FR-013, FR-014, FR-015, FR-016, FR-018, FR-031, SC-002)

**Checkpoint**: la sélection de tâche est confortable ; US2 reste fonctionnelle.

---

## Phase 6: User Story 4 - Suivre son temps librement (Priority: P2)

**Goal**: un second mode de session, à durée libre, avec pause et reprise.

**Independent Test**: démarrer le suivi, attendre 2 min, mettre en pause 1 min, reprendre 1 min, arrêter, vérifier une entrée de 3 min de type Tracker.

### Tests for User Story 4 ⚠️

- [X] T070 [P] [US4] Écrire les tests du mode Tracker dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/TrackerMachineTests.swift` : pauses exclues de la durée, arrêt produisant une entrée « Complété » de type Tracker, règle des 60 s (US4.2, US4.3, US4.5, FR-021)

### Implementation for User Story 4

- [X] T071 [US4] Implémenter le mode Tracker dans `SessionMachine.swift` : démarrage, pause, reprise, arrêt, accumulation de `pauseIntervals` (FR-021)
- [X] T072 [US4] Implémenter le calcul de durée effective hors pauses dans `EntryComposer.swift` (FR-021, FR-026)
- [X] T073 [US4] Implémenter l'affichage du chronomètre et de l'indicateur de pause dans la barre de menus, et les commandes « Pause » et « Arrêter » du menu, dans `App/MenuBar/` (US4.1, FR-025)

**Checkpoint**: les deux modes fonctionnent, indépendamment l'un de l'autre.

---

## Phase 7: User Story 5 - Interruptions, veille et inactivité (Priority: P2)

**Goal**: les données Notion restent fidèles quand la session ne se déroule pas normalement.

**Independent Test**: pomodoro de 10 min arrêté à 4 min ⇒ entrée de 4 min « Écourté » avec commentaire ; suivi libre laissé inactif 6 min avec seuil à 5, choix « retrancher » ⇒ durée finale ajustée.

### Tests for User Story 5 ⚠️

- [X] T074 [P] [US5] Écrire les tests d'écourtement dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/InterruptionTests.swift` : arrêt utilisateur ⇒ « Écourté » + commentaire « arrêt par l'utilisateur » + série remise à zéro (US5.1)
- [X] T075 [P] [US5] Écrire les tests de veille dans `InterruptionTests.swift` : pomodoro clôturé daté de l'instant de la veille avec commentaire « mise en veille » ; tracker mis en pause sans clôture (US5.3, US4.4)
- [X] T076 [P] [US5] Écrire les tests d'inactivité dans `InterruptionTests.swift` : retranchement réduisant la durée sans changer « Complété » ni la série ; activée par défaut en Tracker, désactivée en Pomodoro (US5.4, US5.5, FR-020, FR-024)
- [X] T077 [P] [US5] Écrire les tests de restauration dans `InterruptionTests.swift` : pomodoro retrouvé clôturé « Écourté » au dernier `lastHeartbeatAt` avec commentaire « arrêt inopiné » ; tracker retrouvé en pause (US5.6)

- [X] T078 [P] [US5] Écrire l'assertion de seuil SC-005 dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/DurationAccuracyTests.swift` : sur les deux modes, l'écart entre durée enregistrée et durée réelle simulée reste sous 2 secondes, pauses et inactivité retranchée comprises

### Implementation for User Story 5

- [X] T079 [US5] Implémenter `App/System/WorkspaceSleepObserver.swift` (`NSWorkspace` willSleep / didWake) et son câblage vers les événements `.systemWillSleep` / `.systemDidWake` (R-04)
- [X] T080 [US5] Implémenter le traitement de la veille dans `SessionMachine.swift` : clôture datée pour un pomodoro, pause pour un tracker, persistance avant endormissement (US5.3, FR-021)
- [X] T081 [US5] Implémenter `App/System/EventInactivityMonitor.swift` (`CGEventSource.secondsSinceLastEventType`, sondage à 15 s pendant une session seulement) et lever le point À VÉRIFIER de R-03
- [X] T082 [US5] Implémenter l'accumulation des `idleIntervals` et leur arbitrage avant envoi dans `SessionMachine.swift` (FR-024)
- [X] T083 [US5] Implémenter la restauration au démarrage selon le mode dans `SessionMachine.swift` (US5.6, FR-022)
- [X] T084 [US5] Implémenter l'invite « conserver ou retrancher » et l'information au réveil dans `App/MenuBar/` (US5.3, US5.4)
- [X] T085 [US5] Implémenter la confirmation de sortie pendant une session dans `App/NotitimeApp.swift`, appliquant la règle du mode (cas limite « quitter l'app volontairement »)

**Checkpoint**: l'historique Notion reste fidèle dans tous les scénarios dégradés locaux.

---

## Phase 8: User Story 6 - Ne jamais perdre une entrée de temps (Priority: P3)

**Goal**: aucune entrée perdue ni dupliquée, quelles que soient les conditions réseau.

**Independent Test**: couper le réseau, terminer deux sessions, rétablir, vérifier que les deux entrées arrivent une seule fois chacune et que l'indicateur revient à zéro.

### Tests for User Story 6 ⚠️

- [X] T086 [P] [US6] Écrire les tests d'idempotence dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/OutboxRetryTests.swift` : issue indéterminée ⇒ vérification par `localID` avant réessai ; erreur explicite ⇒ aucune vérification, en comptant les requêtes émises (FR-028, R-06, US6.4)
- [X] T087 [P] [US6] Écrire le test d'écriture de `attemptOutcome` **avant** l'envoi dans `OutboxRetryTests.swift` : un arrêt simulé pendant la requête laisse `indéterminée` en base (R-06)
- [X] T088 [P] [US6] Écrire les tests de classement des erreurs dans `OutboxRetryTests.swift` : `429` avec `Retry-After`, `5xx` et réseau ⇒ réessais indéfinis ; `400`, `403`, `404` ⇒ échec définitif immédiat (FR-029, FR-030, US6.3)
- [X] T089 [P] [US6] Écrire le test d'ordre chronologique de vidage de la file dans `OutboxRetryTests.swift` (US6.2)

- [X] T090 [P] [US6] Écrire la campagne automatisée SC-004 dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/OutboxSoakTests.swift` : 100 sessions enchaînées sous coupures réseau, `429` et arrêts simulés en cours de requête, avec assertions explicites de zéro entrée perdue et zéro entrée dupliquée
- [X] T091 [P] [US6] Écrire le test de double interrogation d'idempotence dans `OutboxRetryTests.swift` : une entrée archivée est détectée par la seconde requête (`is_archived: true`) et n'est pas recréée ; le test consigne la limite bornée de la corbeille documentée en R-06

### Implementation for User Story 6

- [X] T092 [US6] Implémenter le suivi de `attemptOutcome` (écrit avant l'envoi, corrigé à réception) dans `Outbox.swift` (R-06)
- [X] T093 [US6] Implémenter la vérification d'idempotence **conditionnelle** — uniquement avant un réessai d'issue indéterminée — par double interrogation sur la propriété « ID » (`rich_text`), sans `is_archived` puis avec `is_archived: true`, dans `Outbox.swift` (FR-028, R-06)
- [X] T094 [US6] Implémenter le backoff plafonné, le respect de `Retry-After` et la reprise automatique au retour du réseau dans `Outbox.swift` (FR-029, US6.2)
- [X] T095 [US6] Implémenter le marquage d'échec définitif et la conservation locale consultable dans `Outbox.swift` (FR-030, US6.5)
- [X] T096 [US6] Implémenter l'indicateur « N entrées en attente » et le détail d'un échec définitif avec son action de résolution dans `App/MenuBar/` (FR-030)
- [X] T097 [US6] Implémenter la réassignation d'une entrée en échec à une autre tâche avant renvoi dans `App/MenuBar/` et `Outbox.swift` (FR-031, cas limite tâche supprimée)
- [X] T097b [US3] Implémenter le marquage d'une tâche comme terminée depuis l'écran de fin dans `TaskCache.markDone` et `NotionClient.updatePage`, la valeur écrite venant du groupe « terminé » du schéma (FR-011, FR-026)
- [X] T097e [US7] Remplacer les préréglages fixes de FR-018 par une liste de durées réglables (`AppSettings.sessionMinutes`, `DurationPill`) : c'est elle que l'écran de méthode propose (FR-018 revu, US7.2)
- [X] T097d [US3] Écarter une tâche de la liste sans rien écrire dans Notion : ligne locale `HiddenTask` dans le magasin, disparition immédiate, et annonce offrant « Annuler » (FR-013)
- [X] T097c [US3] Changer le statut d'une tâche depuis sa ligne : lecture des valeurs déclarées par la base dans `TaskCache.statusOptions` et écriture par `TaskCache.setStatus`, une valeur du groupe « terminé » sortant la tâche de la liste (FR-010, FR-011)
- [X] T097a [US4] [US6] Implémenter l'écran de fin de session dans `App/MenuBar/CompletionView.swift` : durée travaillée en titre au centre, état d'envoi suivi jusqu'à la page créée, relance sur la même méthode et retour à la liste (FR-023, FR-024, FR-026, FR-030)

**Checkpoint**: SC-004 vérifiable — 100 sessions en conditions dégradées, aucune perte, aucun doublon.

---

## Phase 9: User Story 7 - Réglages et confort (Priority: P3)

**Goal**: l'app s'adapte sans que ses valeurs par défaut obligent jamais à ouvrir les réglages.

**Independent Test**: modifier chaque réglage, relancer l'app, vérifier qu'il est conservé et appliqué.

### Tests for User Story 7 ⚠️

- [X] T098 [P] [US7] Écrire les tests des réglages dans `Packages/NotitimeCore/Tests/NotitimeCoreTests/SettingsTests.swift` : valeurs par défaut de US7.1, persistance d'un préréglage personnalisé, effet du changement de valeurs terminées sur le filtre (US7.2, US7.5)

### Implementation for User Story 7

- [X] T099 [US7] Implémenter le panneau de réglages dans `App/Settings/SettingsView.swift` : durées, préréglages 25/5/15 et 50/10/20, valeurs personnalisées, nombre avant pause longue (FR-018, US7.1, US7.2)
- [X] T100 [P] [US7] Implémenter les réglages d'inactivité par mode (activée en Tracker, désactivée en Pomodoro par défaut) dans `App/Settings/` (FR-024)
- [X] T101 [P] [US7] Implémenter les réglages de notification, de son et d'intervalle de rafraîchissement dans `App/Settings/` (FR-032, FR-009)
- [X] T102 [P] [US7] Implémenter le lancement à l'ouverture de session via `SMAppService.mainApp`, l'état lu depuis `status` et non depuis une préférence locale, dans `App/System/LoginItemService.swift` (FR-033, R-11)
- [X] T103 [P] [US7] Implémenter le mode Concentration optionnel via un raccourci Shortcuts désigné par l'utilisateur dans `App/System/FocusModeService.swift`, l'échec n'empêchant jamais le démarrage d'une session, et lever le point À VÉRIFIER de R-12 (FR-034)
- [X] T104 [US7] Implémenter l'écran de mapping des propriétés et de changement de base et de source, avec revalidation du schéma, dans `App/Settings/BindingsView.swift` (FR-007, US1.6)
- [X] T105 [US7] Implémenter la re-résolution d'une source disparue (une seule ⇒ proposée, plusieurs ⇒ choix redemandé, aucune ⇒ configuration invalide) dans `App/Settings/BindingsView.swift` (FR-006a)
- [X] T106 [P] [US7] Implémenter l'export du journal depuis les réglages dans `App/Settings/` (FR-037)

**Checkpoint**: toutes les user stories sont indépendamment fonctionnelles.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [ ] T107 [P] Externaliser toutes les chaînes dans `App/Resources/Localizable.xcstrings` et vérifier qu'aucune chaîne visible n'est codée en dur (FR-036)
- [X] T108 [P] Implémenter le repli sans propriété Personne quand Notion la refuse pour un invité, avec information unique à l'utilisateur, dans `Packages/NotitimeCore/Sources/NotitimeCore/Outbox/EntryComposer.swift` (cas limite invité)
- [X] T109 [P] Implémenter le remplacement de connexion après confirmation, file de l'ancien workspace vidée ou envoyée avant, dans `Packages/NotitimeCore/Sources/NotitimeCore/Notion/ConnectionService.swift` (cas limite multi-workspace)
- [X] T110 Éliminer tous les warnings Swift produits par `scripts/build.sh` (exigence du workflow de la constitution)
- [X] T111 Vérifier que `scripts/test.sh` passe intégralement en mode avion — aucun test ne doit dépendre du réseau (principe VII)
- [ ] T112 Exécuter les huit validations manuelles de `quickstart.md` et consigner les écarts
- [X] T113 [P] Produire le bundle universel non signé par `scripts/package.sh` et rédiger le guide d'installation (autorisation manuelle dans les réglages de sécurité macOS)
- [X] T114 [P] Créer `CHANGELOG.md` et y consigner les comportements visibles par l'utilisateur (exigence du workflow de la constitution)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)** : aucune dépendance.
- **Foundational (Phase 2)** : dépend de Setup. **Bloque toutes les user stories.**
- **US1 (Phase 3)** : dépend de Foundational. Aucune dépendance sur une autre story.
- **US2 (Phase 4)** : dépend de Foundational. Dépend fonctionnellement d'US1 pour être exerçable de bout en bout (il faut une connexion valide), mais sa logique est testable seule avec des fixtures.
- **US3, US4, US5 (Phases 5 à 7)** : dépendent de Foundational. Parallélisables entre elles.
- **US6 (Phase 8)** : dépend de Foundational et de l'`Outbox` minimal posé en US2 (T053).
- **US7 (Phase 9)** : dépend de Foundational ; T104 et T105 s'appuient sur le validateur d'US1.
- **Polish (Phase 10)** : dépend des stories retenues.

### Ordre de livraison recommandé

`Setup → Foundational → US1 → US2` constitue le MVP. Les phases 5 à 9 s'ajoutent ensuite sans casser ce qui précède.

### Within Each User Story

- Les tests précèdent l'implémentation et doivent échouer d'abord.
- Modèles avant services, services avant interface.
- Une story est close avant de passer à la priorité suivante.

### Parallel Opportunities

- Phase 1 : T003 à T008 en parallèle après T001–T002.
- Phase 2 : T010 à T013 en parallèle ; T018–T021 en parallèle.
- Phase 3 : T023 à T027 (tests) en parallèle ; T028 à T030 (trois routes serverless) en parallèle.
- Toutes les tâches de test d'une même story marquées [P] sont parallélisables.
- US3, US4 et US5 sont attribuables à trois personnes distinctes une fois Foundational terminée.

---

## Parallel Example: User Story 1

```bash
# Les cinq lots de tests de l'US1, en parallèle :
Task: "Tests des trois routes serverless dans backend/tests/"
Task: "Tests du validateur de schéma dans SchemaValidatorTests.swift"
Task: "Tests de découverte des rôles dans DiscoveryTests.swift"
Task: "Test du cas base multi-sources dans DiscoveryTests.swift"
Task: "Tests de rafraîchissement et révocation dans AuthTests.swift"

# Les trois routes serverless, en parallèle :
Task: "Implémenter backend/api/notion/callback.js"
Task: "Implémenter backend/api/notion/token.js"
Task: "Implémenter backend/api/notion/refresh.js"
```

---

## Implementation Strategy

### MVP (US1 + US2)

1. Phase 1 : Setup.
2. Phase 2 : Foundational — bloquant.
3. Phase 3 : US1 — connexion et configuration.
4. Phase 4 : US2 — pomodoro et entrée Notion.
5. **STOP et VALIDER** : les validations manuelles 1 à 4 de `quickstart.md`.

À ce stade l'application est utilisable : elle remplit les deux usages fondateurs du principe V.

### Livraison incrémentale

US3 (confort de sélection) → US4 (second mode) → US5 (fidélité des données) → US6 (fiabilité réseau) → US7 (réglages). Chaque story ajoute de la valeur sans casser les précédentes.

### Notes

- `[P]` = fichiers distincts, aucune dépendance.
- Commits conventionnels, un commit par tâche ou par groupe logique cohérent.
- Aucun merge sur un test cassé (principe VII).
- Deux points À VÉRIFIER de `research.md` sont levés par des tâches nommées : R-03 par T081, R-12 par T103. Les deux autres (budget `willSleepNotification` en R-04, concurrence SwiftData en R-08) se lèvent respectivement à T080 et T017.
