# Implementation Plan: Pomodoro & Time Tracker connecté à Notion

**Branch**: `001-notion-time-tracker` | **Date**: 2026-08-27 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-notion-time-tracker/spec.md`

## Summary

Application macOS résidente dans la barre de menus qui lit les tâches d'un workspace Notion via OAuth, chronomètre des sessions de travail en mode Pomodoro ou Tracker, et écrit chaque session comme page de la base Time Entries. Toute la logique métier — machine à états des sessions, file d'envoi durable et idempotente, client et mapping Notion, validation de schéma, journal — vit dans un package Swift local `NotitimeCore` testable sans réseau ni interface ; la cible applicative n'apporte que SwiftUI, le Keychain et quatre points de contact système (inactivité, veille, notifications, lancement à l'ouverture de session). Le client secret OAuth est porté par trois fonctions serverless sans état sur Vercel, dont le contrat est figé dans [contracts/oauth-backend.md](./contracts/oauth-backend.md).

## Technical Context

**Language/Version**: Swift 5.10, SwiftUI, `MenuBarExtra`, concurrence `async/await` et acteurs. TypeScript pour les trois fonctions serverless.

**Primary Dependencies**: aucune dépendance tierce à l'exécution. Frameworks système uniquement : SwiftUI, SwiftData, `AuthenticationServices`, `Security` (Keychain), `UserNotifications`, `AppKit` (`NSWorkspace`), `CoreGraphics` (`CGEventSource`), `ServiceManagement` (`SMAppService`), `os` (`Logger`). XcodeGen est un outil de build, pas une dépendance embarquée.

**Storage**: SwiftData, magasin local unique dans Application Support. Contenu : cache de tâches et projets, session courante, file d'envoi des entrées de temps, réglages, tâches récentes. Aucun token. Les tokens vivent exclusivement dans le Keychain (`kSecClassGenericPassword`).

**Testing**: XCTest exécuté en CLI sur le package `NotitimeCore` (`swift test`). `scripts/test.sh` enchaîne cette suite puis une **compilation** de la cible applicative par `xcodebuild build` — il n'y a pas de cible de tests applicative, le principe VII n'imposant aucun test SwiftUI et toute la logique testable vivant dans `NotitimeCore`. Le client Notion est testé contre des réponses enregistrées injectées par une implémentation de test du protocole `HTTPTransport` — et non par un `URLProtocol` enregistré globalement, qui imposerait un état partagé et empêcherait la parallélisation. Les fonctions serverless ont leurs propres tests avec un Notion simulé.

**Target Platform**: macOS 14 (Sonoma) et supérieur, Apple Silicon et Intel (binaire universel).

**Project Type**: application de bureau native + package Swift local + trois fonctions serverless, dans un dépôt unique.

**Performance Goals**: entrée visible dans Notion en moins de 10 s après la fin de session dans 95 % des cas (SC-003) ; session démarrée en moins de 5 s et 3 clics depuis l'icône (SC-002) ; écart de durée enregistrée inférieur à 2 s (SC-005) ; ouverture du menu et sélection d'une tâche tenant dans le budget de SC-002 — moins de 5 s et au plus 3 clics depuis l'icône — la recherche filtrant le cache local sans requête (FR-013).

**Constraints**: `Notion-Version` épinglée à `2026-03-11` dans une constante unique, client écrit contre le modèle source de données (R-01) ; débit propre plafonné à 3 req/s toutes routes Notion confondues, `Retry-After` respecté (FR-029) ; au repos, aucune requête hors rafraîchissement périodique des tâches (SC-006) ; durées calculées sur une horloge monotone, début et fin stockés en UTC ; aucune donnée utilisateur côté serveur ; entitlements minimaux, pas de sandbox contournée ; interface en français avec chaînes externalisées.

**Scale/Scope**: un workspace, un utilisateur par installation. Cache dimensionné pour les tâches ouvertes de l'utilisateur — quelques dizaines en pratique, la pagination étant suivie sans plafond (FR-009). File d'envoi dimensionnée pour absorber plusieurs jours hors-ligne. Périmètre applicatif : menu de la barre de menus, panneau de réglages, flux de connexion et d'assignation des bases.

## Constitution Check

*GATE: contrôlé avant Phase 0, re-contrôlé après Phase 1.*

| Principe | Verdict | Justification |
|---|---|---|
| I. Native, résident, léger | PASS | SwiftUI + `MenuBarExtra`, aucune fenêtre permanente, aucune dépendance tierce à l'exécution, aucun processus annexe. Au repos, seul le rafraîchissement périodique des tâches émet du trafic ; il est suspendu quand le menu est fermé et l'app inactive depuis un intervalle. |
| II. Notion est la source de vérité | PASS | SwiftData ne contient que du cache de lecture, l'état de session en cours et la file d'envoi. Aucun rollup, aucune agrégation, aucun écran de statistiques. Les tâches sont lues et jamais modifiées. |
| III. Zéro donnée utilisateur côté serveur | PASS | Les trois fonctions sont sans état et relaient la réponse Notion telle quelle ; aucun log de code, state, verifier ou token. Les tokens ne quittent le Keychain que pour l'en-tête `Authorization`. |
| IV. Une session ne se perd jamais | PASS | État de session persisté à chaque transition, file d'envoi durable, réessais indéfinis sur erreur transitoire, idempotence par identifiant local — propriété `rich_text` nommée « ID » par défaut, valeur générée avant l'envoi — vérifiée avant les seuls réessais d'issue indéterminée (FR-028). |
| V. Simplicité (YAGNI) | PASS | Aucune fonctionnalité hors des deux usages fondateurs. Les seules abstractions introduites sont les quatre protocoles de contact système, nécessaires pour rendre `NotitimeCore` testable sans interface ni réseau (principe VI). |
| VI. Pilotable par un agent | PASS | `project.yml` XcodeGen versionné, `.xcodeproj` généré et ignoré par git, build/test/packaging par scripts CLI. La logique métier est isolée dans `NotitimeCore`, testable par `swift test` sans Xcode. |
| VII. Tests sur la logique, pas sur les pixels | PASS | Machine à états, file d'envoi, mapping et validation de schéma couverts par XCTest. Client Notion testé sur réponses enregistrées. Aucun test SwiftUI obligatoire. |

### Écart accepté — hébergement Vercel et usage commercial

**Statut : ACCEPTÉ le 2026-08-27**, conformément à la clause de gouvernance qui autorise un écart justifié par écrit et accepté avant `tasks`.

**Nature de l'écart.** Les contraintes techniques de la constitution exigent un hébergement « gratuit et autorisant l'usage commercial ». Le contrat fige Vercel, dont l'offre Hobby — la seule gratuite — exclut l'usage commercial ; l'offre Pro est payante.

**Motif de l'acceptation.** La distribution v1 est interne et non commerciale : bundle non signé remis à une équipe restreinte, sans vente, sans licence, sans facturation. Dans ce périmètre, l'usage du plan Hobby ne contrevient pas à ses propres conditions, et l'écart à la constitution reste sans effet pratique.

**Conditions attachées à cette acceptation.**

1. Les trois fonctions restent écrites contre l'API HTTP standard, sans dépendance à une API propriétaire de la plateforme — pas de stockage, de file, de cache ni d'autre primitive spécifique à l'hébergeur. Leur portabilité doit rester vérifiable à tout moment.
2. Le passage en plan Pro, ou la migration vers un hébergeur autorisant l'usage commercial en gratuit, est un **prérequis explicite de la v2 « licence par workspace »**. Cette v2 ne peut pas être livrée sur le plan Hobby.

Toute évolution qui rendrait la v1 commerciale — vente, licence payante, facturation — annule le motif d'acceptation et réactive l'écart.

### Re-contrôle après Phase 1

Les sept principes restent PASS après conception. Trois points relevés par la conception elle-même :

- **Principe V sous tension, arbitré.** La conception introduit quatre protocoles et une horloge injectable, soit cinq abstractions qui n'existent que pour le test. C'est le prix des principes VI et VII : sans elles, ni la machine à états ni la file d'envoi ne sont vérifiables en CI. Aucune autre abstraction n'a été retenue — pas de couche dépôt, pas d'injection généralisée, pas de bus d'événements.
- **Principe III confirmé sur pièce.** La relecture du contrat OAuth confirme qu'aucune route ne stocke ni ne journalise quoi que ce soit, et que le mécanisme `verifier`/`state` empêche une autre application ayant enregistré le scheme `notitime://` d'obtenir les tokens. Le `verifier` ne quitte jamais la mémoire du processus avant l'échange.
- **Une modification du contrat fourni.** La liste des capacités Notion du contrat n'incluait pas l'insertion de commentaires, que FR-026a rend obligatoire. La ligne a été complétée dans `contracts/oauth-backend.md` ; c'est la seule retouche apportée au contrat.

L'écart Vercel reste entier et **conditionne le passage à `tasks`**.

### Écart accepté — développement de la feature 001 sur `main`

**Statut : ACCEPTÉ le 2026-08-27.**

**Nature de l'écart.** Le workflow de développement de la constitution impose que chaque feature soit développée sur sa branche et mergée quand `converge` rapporte Converged. La feature 001 est développée directement sur `main`.

**Motif de l'acceptation.** Dépôt initial, contributeur unique, aucune divergence à gérer : une branche sans point de divergence n'apporte ici ni isolation ni revue, seulement une étape de merge sans contenu.

**Portée de la dérogation.** Elle est limitée à la feature 001. La règle une-branche-par-feature s'applique **à partir de la feature 002, ou dès qu'un second contributeur rejoint le dépôt** — le premier des deux qui survient.

## Project Structure

### Documentation (this feature)

```text
specs/001-notion-time-tracker/
├── plan.md              # Ce fichier
├── spec.md              # Spécification fonctionnelle (39 exigences)
├── research.md          # Phase 0 : décisions techniques et alternatives
├── data-model.md        # Phase 1 : modèle SwiftData et mapping Notion
├── quickstart.md        # Phase 1 : guide de validation exécutable
├── contracts/
│   ├── oauth-backend.md # Contrat des trois fonctions serverless (fourni, figé)
│   ├── notion-api.md    # Surface de l'API Notion consommée
│   └── core-api.md      # Surface publique de NotitimeCore
└── tasks.md             # Phase 2, produit par /speckit-tasks — pas par ce plan
```

### Source Code (repository root)

```text
project.yml                        # Description XcodeGen versionnée
Notitime.xcodeproj/                # Généré par XcodeGen, ignoré par git

App/                               # Cible applicative macOS — SwiftUI et système uniquement
├── NotitimeApp.swift              # MenuBarExtra, cycle de vie, instance unique
├── MenuBar/                       # Menu : liste de tâches, états, contrôles de session
├── Onboarding/                    # Connexion Notion, assignation et validation des bases
├── Settings/                      # Réglages, mapping des propriétés, export du journal
├── System/                        # Implémentations concrètes des protocoles de Core
│   ├── KeychainTokenStore.swift
│   ├── EventInactivityMonitor.swift   # CGEventSource
│   ├── WorkspaceSleepObserver.swift   # NSWorkspace
│   ├── URLSessionTransport.swift
│   ├── NotificationPresenter.swift    # UserNotifications
│   ├── LoginItemService.swift         # SMAppService
│   └── FocusModeService.swift         # Raccourci Shortcuts, optionnel
└── Resources/                     # Info.plist, Localizable.xcstrings, sons, assets

Packages/NotitimeCore/             # Logique métier — sans interface, sans réseau réel
├── Package.swift
├── Sources/NotitimeCore/
│   ├── Session/                   # Machine à états Pomodoro et Tracker
│   ├── Outbox/                    # File d'envoi durable, idempotence, réessais
│   ├── Notion/                    # Client, mapping des propriétés, validation de schéma
│   ├── Persistence/               # Modèles SwiftData et accès
│   ├── Logging/                   # Journal rotatif borné
│   └── Support/                   # Horloges, limiteur de débit, protocoles système
└── Tests/NotitimeCoreTests/
    └── Fixtures/                  # Réponses Notion enregistrées (JSON)

backend/                           # Fonctions serverless Vercel, sans état
├── api/notion/callback.js         # JS ESM et non TS : Node n'exécute pas TS sans
├── api/notion/token.js            # transpilation, et ajouter tsc contredirait la
├── api/notion/refresh.js          # contrainte « aucune dépendance » (portabilité)
├── tests/
├── package.json
└── vercel.json

scripts/                           # generate.sh, build.sh, test.sh, package.sh
docs/notion-schema.md              # Schéma attendu des bases Notion
```

**Structure Decision**: dépôt unique à trois racines de code. `Packages/NotitimeCore` concentre tout ce qui est testable sans machine réelle et n'importe ni SwiftUI ni AppKit ; il expose quatre protocoles (`TokenStore`, `InactivityMonitor`, `SleepObserver`, `HTTPTransport`) que `App/System/` implémente avec les frameworks système. Cette frontière est ce qui rend le principe VII applicable : les tests injectent une horloge contrôlée, un transport rejouant des fixtures et des sondes système simulées, sans jamais toucher au Keychain, au réseau ni aux événements d'entrée réels. `backend/` est indépendant du code Swift et se déploie séparément.

## Comportements système attendus — à ne pas prendre pour des défauts

**Le flux OAuth s'ouvre dans Safari, pas dans le navigateur par défaut.**
`ASWebAuthenticationSession` délègue la présentation au système, qui utilise son
propre moteur web — Safari sur macOS — indépendamment du navigateur défini par
défaut dans les Réglages Système. C'est le comportement voulu par Apple, et il
n'est pas configurable : l'API n'expose aucun moyen de choisir le navigateur.

C'est aussi ce qui fait sa valeur. La session est gérée par le système, l'app ne
voit jamais la page d'autorisation ni ce que l'utilisateur y saisit, et le flux
ne peut pas être détourné par une extension installée dans un autre navigateur.

Conséquence pratique : l'utilisateur doit être connecté à Notion **dans Safari**
pour ne pas ressaisir ses identifiants. C'est la raison de
`prefersEphemeralWebBrowserSession = false` : une session éphémère l'obligerait à
se reconnecter à Notion à chaque autorisation.

La seule alternative serait d'ouvrir l'URL dans le navigateur par défaut avec
`NSWorkspace` et de recevoir le callback par le scheme `notitime://`. Elle est
écartée : elle perd l'isolation de la session, expose la page d'autorisation aux
extensions du navigateur, et laisse n'importe quelle application ayant enregistré
le scheme intercepter le retour sans que le système n'arbitre.

**macOS redemande le mot de passe du trousseau après chaque build.**
Le bundle v1 n'est pas signé. Son identité de code change donc d'une compilation
à l'autre, et le trousseau ne reconnaît plus l'application qui avait créé
l'entrée `com.notitime.app` : il exige l'accord explicite de l'utilisateur avant
de la rouvrir. Ce n'est ni une fuite, ni un défaut de l'application — c'est la
protection du trousseau qui fonctionne comme prévu.

Conséquences pratiques :

- « Toujours autoriser » vaut pour l'identité de code courante. Le prochain build
  non signé resollicitera l'utilisateur ; ce sera stable dès que le bundle sera
  signé avec un identifiant d'équipe (voir la dette technique ci-dessous).
- Le refus est un cas ordinaire, pas une panne. `KeychainTokenStore.KeychainError`
  distingue `errSecUserCanceled`, `errSecAuthFailed` et `errSecInteractionNotAllowed`
  d'une véritable erreur, et porte un message et une conduite à tenir.
- **Un refus ne déconnecte jamais.** Les tokens ne sont effacés que sur révocation
  côté Notion (`invalid_grant`) ou déconnexion volontaire, jamais sur un échec
  d'accès au trousseau — sans quoi un clic sur « Refuser » obligerait à refaire
  tout le parcours OAuth. Deux tests le verrouillent dans `AuthTests`.
- **Une sollicitation par lancement, pas une par requête.** Le trousseau est la
  seule persistance des jetons (principe III), mais `ConnectionService` en garde
  un relais en mémoire pour la durée de la session : la lecture a lieu au premier
  besoin, ou jamais si la connexion vient d'écrire les jetons. Sans ce relais,
  chaque requête HTTP déclenchait un `SecItemCopyMatching` — six pour un cycle
  ordinaire (tâches paginées, envoi, réessai), et davantage à chaque réessai de la
  file : la demande de mot de passe revenait en boucle et rendait l'application
  inutilisable. Les lectures simultanées sont mutualisées, le relais est vidé à la
  déconnexion comme à la révocation, et remplacé par le jeton renouvelé après un
  rafraîchissement. `KeychainAccessTests` compte les lectures sur un cycle complet ;
  le journal porte une ligne `jeton lu au trousseau` qui doit rester unique.

**Ce qui interrompt une session, et ce qui ne l'interrompt pas.**
La règle est de s'en tenir à ce que le système annonce. Trois notifications
seulement sont *traitées*, et une détection d'horloge sert de filet :

| Événement | Pomodoro | Suivi libre | Pause |
| --- | --- | --- | --- |
| `willSleepNotification` | clos, « Écourté », daté à la veille | mis en pause | terminée |
| `didWakeNotification` | — (déjà clos) | reprend | — |
| Saut d'horloge ≥ 30 s | clos, daté au dernier tick connu | le trou est retranché, la session continue | terminée |
| `screensDidSleep` / `screensDidWake` | rien | rien | rien |
| `screenIsLocked` / `screenIsUnlocked` | rien | rien | rien |
| `sessionDidResignActive` / `…BecomeActive` | rien | rien | rien |
| `willPowerOff` | rien | rien | rien |

Les quatre dernières lignes sont **observées et journalisées, jamais traitées**.
Aucune n'est une veille : fermer le clapet avec un écran externe branché
n'endort pas le Mac, et derrière un écran verrouillé le travail peut très bien
continuer — une réunion, un appel, une lecture. Interrompre sur ces signaux
retrancherait du temps réellement travaillé, ce qui est le sens contraire de
FR-024, qui exige déjà l'accord de l'utilisateur avant de retrancher une
inactivité pourtant mesurée. **Le verrouillage sans veille n'est donc pas
couvert, délibérément** : il est journalisé pour qu'on puisse en décider sur
pièces, et le point reste ouvert.

**Le saut d'horloge est le seul filet indépendant du système.** Le minuteur bat
à la seconde ; un écart de trente secondes ou plus entre deux ticks prouve que
le processus n'a pas tourné, quelle qu'en soit la cause — veille non annoncée,
notification manquée, suspension par macOS. La seule date sûre est celle du
dernier tick : c'est elle qui borne le temps compté. Sans ce filet, un pomodoro
traversant une suspension était enregistré « Complété » avec sa durée pleine,
alors que rien n'avait été travaillé pendant le trou.

**Les notifications système exigent une identité de code.**
`UNUserNotificationCenter` refuse d'accorder une autorisation à un bundle sans
identité de code stable : `requestAuthorization` échoue en `UNErrorDomain`, et
aucune notification n'est présentée. C'est la même racine que la sollicitation
du trousseau ci-dessus — l'absence de signature —, mais la conséquence diffère :
le trousseau demande confirmation à l'utilisateur, le centre de notifications,
lui, refuse sans recours.

Ce qui est fait, et ce qui ne l'est pas :

- `scripts/package.sh` applique désormais une **signature ad-hoc**
  (`codesign --sign -`). Elle ne coûte ni compte développeur ni certificat et
  donne au bundle une identité de code. C'est la seule piste sans signature
  Developer ID ; si elle ne suffit pas sur une machine donnée, les notifications
  y resteront indisponibles jusqu'à une vraie signature.
- **Le son de fin ne dépend pas de tout cela.** Il est joué par `NSSound`, en
  amont de toute autorisation, et reste donc audible même quand la notification
  est refusée. C'est le retour de fin de session garanti par défaut (FR-032).
- Le journal consigne le domaine et le code exacts de l'erreur, pour distinguer
  un refus d'autorisation d'une indisponibilité du service.

À noter : `NSSound(named:)?.play()` ne joue rien de fiable. `play()` rend la
main immédiatement et l'objet temporaire est libéré avant la fin de la lecture ;
le son doit être retenu le temps qu'il s'exécute. C'est ce qui expliquait
l'absence de son en plus de l'absence de notification.

## Dette technique assumée

**Mode langage Swift 5 sur toolchain 6.3.3.** Le package est déclaré en `swift-tools-version:5.10`, conformément au socle « Swift 5.10 minimum » des contraintes techniques. La toolchain réellement installée est la 6.3.3, mais la déclaration place la compilation en **mode langage Swift 5** : la vérification stricte de la concurrence n'est donc pas appliquée, et les annotations `Sendable` ne sont pas contrôlées par le compilateur.

C'est un choix de vitesse à court terme, pas un oubli. Il a un coût différé identifié : le passage en mode Swift 6 demandera un travail d'annotation `Sendable` concentré sur les trois composants qui partagent de l'état entre tâches concurrentes — la machine à états du timer, le limiteur de débit et l'`Outbox`. Les deux derniers sont déjà des acteurs, ce qui limite l'ampleur ; la machine à états, elle, devra être revue en entier.

À traiter comme une feature à part entière, pas au détour d'une tâche de l'US en cours.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Quatre protocoles d'abstraction système dans `NotitimeCore` | Le principe VI impose que la logique métier soit testable sans interface ni réseau ; l'inactivité, la veille, le Keychain et HTTP sont les quatre seules frontières où cette logique touche la machine | Appeler `CGEventSource`, `NSWorkspace`, `Security` et `URLSession` directement depuis Core rendrait la machine à états et la file d'envoi non testables en CI, ce qui contredit le principe VII |
| Hébergement Vercel malgré la clause d'usage commercial | Contrat fourni et figé ; l'écart est sans effet en v1 (distribution interne, non commerciale) | Voir « Écart à accepter » ci-dessus : à trancher avant la v2, pas avant la v1 |
