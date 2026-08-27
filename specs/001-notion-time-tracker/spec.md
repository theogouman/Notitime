# Feature Specification: Pomodoro & Time Tracker connecté à Notion

**Feature Branch**: `001-notion-time-tracker`

**Created**: 2026-08-27

**Status**: Draft

**Input**: User description: "Application macOS résidant dans la barre de menus qui récupère les tâches Notion de l'utilisateur via OAuth, permet de démarrer des sessions de travail en mode Pomodoro ou en suivi libre sur une tâche donnée, et envoie chaque session comme entrée de temps dans une base Notion afin de centraliser et d'analyser la répartition du temps."

## Clarifications

### Session 2026-08-27

- Q: Par quel mécanisme le code d'autorisation OAuth revient-il de Notion vers l'app dans la barre de menus ? (FR-001) → A: `ASWebAuthenticationSession` ; redirect URI HTTPS vers le service serveur, qui redirige vers le schéma d'URL personnalisé `notitime://auth` porté par l'app.
- Q: Comment l'app garantit-elle qu'un réessai ne crée jamais de doublon dans Time Entries ? (FR-028) → A: La première tentative crée l'entrée directement (1 requête). La recherche par « Identifiant local » n'a lieu qu'avant un réessai consécutif à une réponse ambiguë (délai dépassé, coupure pendant la requête, réponse non reçue) ; un réessai qui suit une réponse d'erreur explicite de Notion s'en dispense.
- Q: Quand un envoi devient-il un échec définitif ? (FR-029, FR-030) → A: Classement par type d'erreur : erreurs permanentes (400, 403, 404) en échec définitif immédiat sans réessai ; erreurs transitoires (réseau, 429, 5xx) réessayées indéfiniment avec backoff plafonné, jamais abandonnées.
- Q: Jusqu'où va la récupération des tâches mises en cache ? (FR-009) → A: Filtres poussés côté API (statut non terminé + personne courante), pagination suivie jusqu'au bout sans plafond ; la recherche au clavier filtre le cache local sans requête réseau.
- Q: Quand de l'inactivité est retranchée d'un pomodoro allé jusqu'à zéro, que valent le statut et la durée enregistrés ? (FR-019, FR-024) → A: La propriété Statut porte deux valeurs, « Complété » (session allée à son terme) et « Écourté » (arrêt par l'utilisateur, mise en veille, arrêt inopiné). La durée enregistrée est toujours la durée réellement travaillée, inactivité retranchée — un pomodoro allé à son terme dont on retranche de l'inactivité reste « Complété ». Le motif précis de l'écourtement reste un commentaire sur la page de l'entrée, publié après création réussie de celle-ci, et n'est pas une propriété.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Connecter Notion et configurer les bases (Priority: P1)

Au premier lancement, l'utilisateur clique sur « Connecter mon Notion ». Notion lui propose soit de dupliquer le template fourni (contenant les bases Projets, Tâches et Time Entries déjà reliées), soit de sélectionner des pages existantes. Dans le premier cas, l'application détecte les trois bases toute seule. Dans le second, elle liste les bases auxquelles elle a accès et demande à l'utilisateur de désigner la base Tâches et la base Time Entries (la base Projets est optionnelle) ; elle vérifie que les propriétés requises existent et propose de créer celles qui manquent. À la fin, l'utilisateur voit son nom, le nom du workspace et les bases connectées.

**Why this priority**: Rien ne fonctionne sans connexion et sans bases valides. C'est aussi l'étape où un collègue rejoint : en partageant la page parente du template dupliqué par un premier membre, ses bases sont détectées sans configuration.

**Independent Test**: Sur un workspace vierge, dupliquer le template via le flow OAuth et constater que les trois bases sont reconnues ; sur un second compte du même workspace, partager la page existante et constater la même reconnaissance ; sur une base Tâches à laquelle il manque une propriété, constater la proposition de création et sa réussite.

**Acceptance Scenarios**:

1. **Given** l'app n'est pas connectée, **When** l'utilisateur lance la connexion et duplique le template, **Then** l'app reconnaît les bases Projets, Tâches et Time Entries issues du template, enregistre le token de façon sécurisée et affiche l'état « Connecté ».
2. **Given** l'app n'est pas connectée, **When** l'utilisateur choisit des pages existantes contenant plusieurs bases, **Then** l'app présente la liste des bases accessibles et demande d'assigner les rôles Tâches, Time Entries et (optionnel) Projets.
3. **Given** une base assignée au rôle Time Entries sans propriété de type relation vers les tâches, **When** l'utilisateur valide, **Then** l'app affiche les propriétés manquantes et propose de les créer ; après acceptation, la validation passe.
4. **Given** l'utilisateur annule l'autorisation dans Notion, **When** il revient à l'app, **Then** l'app reste déconnectée et affiche un message clair sans erreur technique.
5. **Given** l'app est connectée, **When** le token devient invalide (révocation dans Notion), **Then** l'app le détecte à la prochaine requête, informe l'utilisateur et propose de se reconnecter, sans perdre les sessions en attente d'envoi.
6. **Given** l'app est connectée, **When** l'utilisateur change l'identifiant d'une base dans les réglages, **Then** l'app revalide le schéma de la nouvelle base avant d'accepter le changement.

---

### User Story 2 - Lancer un Pomodoro sur une tâche et retrouver l'entrée dans Notion (Priority: P1)

L'utilisateur clique sur l'icône de la barre de menus, choisit une tâche, choisit une durée de pomodoro (préréglage ou personnalisée) et démarre. Le temps restant s'affiche dans la barre de menus. À la fin, une notification système et un son l'avertissent, et une entrée de temps apparaît dans la base Time Entries de Notion, reliée à la tâche, avec début, fin, durée, type Pomodoro, statut Complété et l'utilisateur. Une pause (courte ou longue) est proposée, non comptabilisée.

**Why this priority**: C'est la boucle de valeur complète : une session sur une tâche, un relevé dans Notion. À elle seule elle constitue un produit utilisable.

**Independent Test**: Avec une base Tâches contenant au moins une tâche, démarrer un pomodoro de 1 minute sur cette tâche, attendre la fin, et vérifier dans Notion la présence d'une entrée correctement remplie et reliée.

**Acceptance Scenarios**:

1. **Given** l'app est connectée et une tâche est sélectionnée, **When** l'utilisateur démarre un pomodoro de 25 minutes, **Then** la barre de menus affiche le compte à rebours et le nom court de la tâche, et le menu propose uniquement « Arrêter ».
2. **Given** un pomodoro est en cours, **When** le compte à rebours atteint zéro, **Then** une notification et un son sont émis, une entrée Time Entry est créée dans Notion avec statut Complété, et le menu propose de démarrer une pause ou un nouveau pomodoro sur la même tâche.
3. **Given** quatre pomodoros complétés se sont enchaînés, **When** le quatrième se termine, **Then** la pause proposée est la pause longue.
4. **Given** une pause est en cours, **When** elle se termine, **Then** aucune entrée n'est créée et l'utilisateur est notifié.
5. **Given** aucune tâche n'est sélectionnée, **When** l'utilisateur tente de démarrer, **Then** le démarrage est impossible et l'app invite à choisir une tâche.
6. **Given** une session est en cours, **When** l'utilisateur tente d'en démarrer une autre, **Then** l'app refuse tant que la session courante n'est pas arrêtée.

---

### User Story 3 - Trouver sa tâche en quelques secondes (Priority: P2)

Dans le menu, l'utilisateur voit d'abord ses tâches récentes (celles sur lesquelles il a travaillé dernièrement), puis peut taper pour filtrer parmi ses tâches ouvertes. Chaque tâche affiche son projet. Par défaut, seules les tâches qui lui sont assignées et non terminées sont proposées.

**Why this priority**: Une tâche étant obligatoire pour démarrer, la friction de sélection décide de l'adoption. Sans cette histoire, l'US2 fonctionne mais avec une liste brute.

**Independent Test**: Avec une base de 200 tâches dont 15 assignées à l'utilisateur, ouvrir le menu et constater que seules ces 15 (moins les terminées) apparaissent, que la recherche filtre en temps réel et que les tâches récentes sont en tête.

**Acceptance Scenarios**:

1. **Given** la base Tâches a une propriété Personne mappée, **When** l'utilisateur ouvre le menu, **Then** seules les tâches contenant l'utilisateur courant et dont le statut n'est pas considéré terminé sont listées.
2. **Given** la base Tâches n'a pas de propriété Personne mappée, **When** l'utilisateur ouvre le menu, **Then** toutes les tâches non terminées sont listées.
3. **Given** le réglage « afficher les tâches non assignées » est activé, **When** l'utilisateur ouvre le menu, **Then** les tâches sans personne assignée s'ajoutent à la liste.
4. **Given** l'utilisateur tape « fact », **When** la liste se met à jour, **Then** seules les tâches dont le titre ou le projet contient « fact » (insensible à la casse et aux accents) restent visibles.
5. **Given** l'utilisateur a travaillé sur trois tâches aujourd'hui, **When** il ouvre le menu, **Then** ces trois tâches apparaissent en tête, section « Récentes », même si elles sont hors du filtre courant.
6. **Given** la base Tâches a été modifiée dans Notion, **When** l'utilisateur ouvre le menu, **Then** la liste reflète les changements au plus tard après l'intervalle de rafraîchissement configuré, et immédiatement s'il déclenche un rafraîchissement manuel.
7. **Given** l'app vient d'être connectée et aucune tâche n'est encore en cache, **When** l'utilisateur ouvre le menu pendant le premier chargement, **Then** un indicateur de progression occupe la place de la liste, sans message d'erreur ni liste vide trompeuse.
8. **Given** la base Tâches contient des tâches mais aucune n'est assignée à l'utilisateur courant, **When** il ouvre le menu, **Then** la liste vide est accompagnée d'un message le disant explicitement et de l'action « afficher aussi les tâches non assignées ».
9. **Given** la base Tâches ne contient aucune tâche non terminée, **When** l'utilisateur ouvre le menu, **Then** le message distingue ce cas du précédent et propose d'ouvrir la base dans Notion.
10. **Given** une recherche ne correspond à aucune tâche, **When** la liste se vide, **Then** le message indique que c'est le filtre courant qui est trop restrictif et propose d'effacer la recherche.
11. **Given** Notion est injoignable et un cache de tâches existe, **When** l'utilisateur ouvre le menu, **Then** les tâches du cache restent listées et sélectionnables pour démarrer une session, et un message indique l'heure de la dernière synchronisation réussie.

---

### User Story 4 - Suivre son temps librement sur une tâche (Priority: P2)

Pour un travail dont on ne connaît pas la durée, l'utilisateur choisit une tâche et démarre le suivi libre. Le temps écoulé s'affiche dans la barre de menus. Il peut mettre en pause, reprendre, puis arrêter. À l'arrêt, une entrée de type Tracker est créée dans Notion avec le temps effectif (pauses exclues).

**Why this priority**: Deuxième mode fondateur du produit ; indépendant du Pomodoro, il partage la sélection de tâche et l'envoi Notion.

**Independent Test**: Démarrer le suivi sur une tâche, attendre 2 minutes, mettre en pause 1 minute, reprendre 1 minute, arrêter, et vérifier dans Notion une entrée de 3 minutes de type Tracker.

**Acceptance Scenarios**:

1. **Given** une tâche est sélectionnée, **When** l'utilisateur démarre le suivi libre, **Then** le chronomètre s'affiche dans la barre de menus et le menu propose « Pause » et « Arrêter ».
2. **Given** le suivi est en pause, **When** l'utilisateur reprend, **Then** le temps de pause n'est pas comptabilisé dans la durée.
3. **Given** le suivi est actif, **When** l'utilisateur arrête, **Then** une entrée Time Entry de type Tracker et statut Complété est créée avec début, fin et durée effective.
4. **Given** le suivi est actif, **When** le Mac se met en veille, **Then** le suivi passe en pause automatiquement et le reste jusqu'à action de l'utilisateur au réveil.
5. **Given** le suivi est actif depuis moins d'une minute, **When** l'utilisateur arrête, **Then** aucune entrée n'est créée et l'utilisateur en est informé.

---

### User Story 5 - Interruptions, veille et inactivité (Priority: P2)

Quand un pomodoro est arrêté avant la fin, l'entrée est tout de même envoyée avec la durée réellement travaillée et le statut « Écourté », et un commentaire Notion sur la page de l'entrée précise le motif, pour que l'historique reste fidèle. La mise en veille du Mac interrompt un pomodoro (l'arrêt est daté au moment de la veille) et met en pause un suivi libre. Si l'utilisateur ne touche plus à son Mac pendant un délai configurable durant un suivi libre, l'app le lui signale à son retour et lui propose de conserver ou de retrancher le temps d'inactivité.

**Why this priority**: Sans ces règles, les données Notion sont fausses (temps gonflé par la veille, sessions fantômes) et l'analyse perd son sens.

**Independent Test**: Démarrer un pomodoro de 10 minutes, l'arrêter à 4 minutes, vérifier une entrée de 4 minutes au statut « Écourté » portant un commentaire « arrêt par l'utilisateur » ; démarrer un suivi libre, laisser le Mac inactif 6 minutes avec seuil à 5, revenir, choisir « retrancher », vérifier la durée finale.

**Acceptance Scenarios**:

1. **Given** un pomodoro est en cours depuis 4 minutes sur 25, **When** l'utilisateur arrête, **Then** une entrée de 4 minutes au statut « Écourté » est créée, un commentaire Notion sur sa page indique « arrêt par l'utilisateur », et la série de pomodoros consécutifs est remise à zéro.
2. **Given** un pomodoro est en cours depuis moins d'une minute, **When** l'utilisateur arrête, **Then** aucune entrée n'est créée.
3. **Given** un pomodoro est en cours, **When** le Mac se met en veille, **Then** la session est arrêtée avec fin datée à l'instant de la veille, l'entrée porte le statut « Écourté » avec un commentaire Notion indiquant « mise en veille », et l'utilisateur en est informé au réveil.
4. **Given** un suivi libre est actif et la détection d'inactivité est activée avec un seuil de 5 minutes, **When** aucun événement d'entrée n'est détecté pendant 5 minutes puis l'utilisateur revient, **Then** l'app lui propose de conserver ou retrancher la durée d'inactivité ; le retrait ajuste la durée de l'entrée finale.
5. **Given** un pomodoro est en cours et la détection d'inactivité est activée pour le mode Pomodoro (désactivée par défaut), **When** le seuil est dépassé, **Then** le même choix conserver/retrancher est proposé à la fin de la session.
6. **Given** l'app est fermée ou plante pendant une session, **When** elle est relancée, **Then** la session est retrouvée : un pomodoro est clôturé à la date du dernier état connu, son entrée portant le statut « Écourté » et un commentaire Notion indiquant « arrêt inopiné de l'application » ; un suivi libre est présenté en pause avec la possibilité de reprendre ou d'arrêter.

---

### User Story 6 - Ne jamais perdre une entrée de temps (Priority: P3)

Quand Notion est injoignable (hors-ligne, panne, rate limit), les entrées de temps sont mises en file localement et envoyées dès que possible, sans intervention et sans doublon. L'utilisateur voit dans le menu combien d'entrées attendent l'envoi.

**Why this priority**: Indispensable à la fiabilité mais invisible tant que tout fonctionne ; peut être livré après les fonctions de base à condition que la persistance locale soit prévue dès le début.

**Independent Test**: Couper le réseau, terminer deux sessions, rétablir le réseau, vérifier que les deux entrées arrivent dans Notion une seule fois chacune et que l'indicateur d'attente revient à zéro.

**Acceptance Scenarios**:

1. **Given** le réseau est coupé, **When** une session se termine, **Then** l'entrée est stockée localement, le menu indique « 1 entrée en attente », et l'utilisateur peut continuer à démarrer des sessions.
2. **Given** deux entrées sont en attente, **When** le réseau revient, **Then** elles sont envoyées dans l'ordre chronologique sans action de l'utilisateur.
3. **Given** Notion répond par une limitation de débit, **When** l'app envoie une entrée, **Then** elle respecte le délai demandé et réessaie sans perdre l'entrée.
4. **Given** un envoi a réussi côté Notion mais la réponse n'a pas été reçue, **When** l'app réessaie, **Then** aucune entrée en double n'apparaît dans Notion.
5. **Given** une entrée échoue définitivement (base supprimée, permissions retirées), **When** l'app abandonne les réessais, **Then** l'entrée reste consultable localement et l'utilisateur est informé de la cause avec une action de résolution (reconnecter, changer de base).

---

### User Story 7 - Réglages et confort (Priority: P3)

L'utilisateur ajuste les durées des pomodoros et des pauses (préréglages 25/5/15 et 50/10/20, ou valeurs personnalisées), le nombre de pomodoros avant une pause longue, l'activation et le seuil de détection d'inactivité par mode, les notifications et le son, le lancement à l'ouverture de session, l'activation du mode Concentration macOS pendant un pomodoro, le mapping des propriétés Notion et les identifiants de bases.

**Why this priority**: Confort et adaptabilité ; les valeurs par défaut doivent permettre d'utiliser l'app sans jamais ouvrir les réglages.

**Independent Test**: Modifier chaque réglage, relancer l'app, vérifier qu'il est conservé et appliqué.

**Acceptance Scenarios**:

1. **Given** les réglages par défaut, **When** l'utilisateur démarre un pomodoro sans choisir de durée, **Then** la durée est 25 minutes, la pause courte 5, la longue 15 après 4 pomodoros.
2. **Given** l'utilisateur définit un pomodoro personnalisé de 40 minutes, **When** il démarre, **Then** le compte à rebours part de 40 minutes et le préréglage est proposé les fois suivantes.
3. **Given** le lancement à l'ouverture de session est activé, **When** l'utilisateur se connecte à macOS, **Then** l'app apparaît dans la barre de menus sans fenêtre.
4. **Given** le mode Concentration est activé dans les réglages, **When** un pomodoro démarre, **Then** l'app demande à macOS d'activer le mode Concentration configuré et le désactive à la fin (sous réserve des autorisations accordées par l'utilisateur).
5. **Given** l'utilisateur modifie le nom de la propriété « Statut » et les valeurs considérées comme terminées, **When** il ouvre le menu, **Then** le filtre des tâches ouvertes utilise la nouvelle configuration.

---

### Edge Cases

- Que se passe-t-il si l'utilisateur possède plusieurs workspaces Notion ? Un seul est supporté en v1 ; une nouvelle connexion remplace la précédente après confirmation, la file d'envoi de l'ancien workspace étant vidée ou envoyée avant.
- Que se passe-t-il si la tâche sélectionnée est supprimée ou archivée dans Notion pendant la session ? L'entrée est envoyée avec la relation ; si Notion la refuse, l'entrée reste en file avec une erreur explicite et l'utilisateur peut la réassigner à une autre tâche.
- Que se passe-t-il quand l'horloge du Mac change (fuseau, heure d'été, correction NTP) pendant une session ? La durée est calculée sur une horloge monotone ; début et fin sont stockés en UTC.
- Que se passe-t-il si l'utilisateur quitte l'app volontairement pendant une session ? L'app demande confirmation et applique la règle de l'US5 (pomodoro interrompu, tracker en pause).
- Que se passe-t-il si deux instances de l'app sont lancées ? La seconde se ferme avec un message.
- Que se passe-t-il si la base Time Entries a la propriété Personne mais que l'utilisateur courant n'est pas membre du workspace (invité) ? L'entrée est créée avec la personne si Notion l'accepte, sinon sans, et l'utilisateur en est informé une fois.
- Que se passe-t-il si une base assignée à un rôle porte plusieurs sources de données ? L'application présente les sources et demande laquelle porte le rôle, plutôt que d'en choisir une ou d'échouer (FR-006a). Le cas se produit sans action de l'utilisateur dans l'application : il suffit qu'une seconde source soit ajoutée à la base côté Notion.
- Que se passe-t-il si le template a été modifié par l'équipe (propriété renommée) ? La validation de schéma échoue au prochain démarrage et l'utilisateur est invité à re-mapper.
- Que se passe-t-il si le rafraîchissement du token échoue alors que des entrées sont en attente ? Les entrées restent en file ; la reconnexion les libère.
- Que se passe-t-il si une pause longue est en cours et que l'utilisateur veut travailler ? Il peut interrompre la pause et démarrer immédiatement ; aucune entrée n'est créée pour la pause.

## Requirements *(mandatory)*

### Functional Requirements

**Connexion et configuration**

- **FR-001**: L'application MUST s'authentifier auprès de Notion exclusivement par OAuth 2.0 (connexion publique), l'échange du code et le rafraîchissement du token passant par un service serveur sans état qui ne conserve aucune donnée. Le flux d'autorisation MUST se dérouler dans une `ASWebAuthenticationSession` ; l'URL de redirection déclarée dans l'intégration Notion MUST pointer vers le service serveur, qui MUST rediriger vers le schéma d'URL personnalisé `notitime://auth` porté par l'application (voir `contracts/oauth-backend.md`) ; l'application MUST NOT ouvrir de port en écoute pour recevoir le callback.
- **FR-002**: L'application MUST stocker le token d'accès et le token de rafraîchissement dans le Keychain macOS et MUST rafraîchir le token d'accès automatiquement avant expiration ou sur rejet.
- **FR-003**: L'application MUST conserver localement les identifiants de workspace, de bot et d'utilisateur retournés lors de l'autorisation, ainsi que le nom et l'icône du workspace pour affichage.
- **FR-004**: Lorsque l'autorisation retourne un identifiant de template dupliqué, l'application MUST découvrir automatiquement les bases Projets, Tâches et Time Entries dans la page dupliquée, résoudre pour chacune sa ou ses sources de données, et assigner à chaque rôle la source dont le schéma correspond.
- **FR-005**: En l'absence de template dupliqué, l'application MUST lister les sources de données accessibles et permettre à l'utilisateur d'assigner les rôles Tâches (requis), Time Entries (requis) et Projets (optionnel) ; l'application SHOULD pré-sélectionner automatiquement les sources dont le titre et le schéma correspondent au template.
- **FR-006**: L'application MUST valider le schéma de chaque source de données assignée par rapport aux propriétés requises (voir Key Entities) et MUST proposer de créer les propriétés manquantes ; elle MUST refuser la configuration tant que le schéma n'est pas valide.
- **FR-007**: L'application MUST permettre à tout moment, dans les réglages, de changer la base et la source de données liées à chaque rôle ainsi que le mapping des propriétés, avec revalidation du schéma.
- **FR-006a**: Lorsqu'une base assignée à un rôle expose plusieurs sources de données, l'application MUST présenter ces sources à l'utilisateur et lui demander laquelle porte le rôle ; elle MUST NOT en choisir une d'office et MUST NOT échouer. Si un choix mémorisé désigne une source qui n'existe plus, l'application MUST re-résoudre les sources de la base : s'il n'en subsiste qu'une, elle la propose ; s'il y en a plusieurs, elle redemande le choix ; s'il n'y en a aucune, la configuration devient invalide et l'utilisateur est invité à réassigner le rôle.
- **FR-008**: L'application MUST permettre de se déconnecter, ce qui supprime les tokens du Keychain, et MUST avertir si des entrées sont encore en attente d'envoi.

**Tâches**

- **FR-009**: L'application MUST récupérer les tâches de la base Tâches et les mettre en cache localement, avec rafraîchissement automatique à intervalle configurable (défaut 5 minutes) et rafraîchissement manuel. Les filtres (statut non terminé, et personne courante lorsque la propriété Personne est mappée) MUST être poussés dans la requête Notion plutôt qu'appliqués après coup, et la pagination MUST être suivie jusqu'à la dernière page, sans plafond de résultats ni troncature silencieuse.
- **FR-010**: L'application MUST exclure les tâches dont la propriété Statut a une valeur configurée comme terminée (défaut : les valeurs du groupe « Terminé » de Notion, sinon les valeurs nommées Done/Terminé/Fait).
- **FR-011**: Si une propriété de type Personne est mappée sur la base Tâches, l'application MUST ne présenter que les tâches contenant l'utilisateur courant, plus les tâches non assignées si le réglage correspondant est activé.
- **FR-012**: L'application MUST afficher pour chaque tâche le titre et, si disponible, le nom du projet lié.
- **FR-013**: L'application MUST proposer une recherche textuelle instantanée sur le titre de la tâche et le nom du projet, insensible à la casse et aux accents. Cette recherche MUST s'appliquer au cache local et MUST NOT déclencher de requête réseau.
- **FR-014**: L'application MUST présenter en tête les tâches récemment utilisées (défaut : 5 dernières), quel que soit le filtre courant, tant qu'elles ne sont pas terminées.
- **FR-015**: L'application MUST exiger qu'une tâche soit sélectionnée avant tout démarrage de session, en mode Pomodoro comme en suivi libre.
- **FR-015a**: Le menu MUST rendre explicite chaque état de la liste de tâches, sans jamais présenter une liste vide sans explication : (a) pendant le premier chargement, un indicateur de progression ; (b) lorsque la liste est vide, un message distinguant la cause — aucune tâche assignée à l'utilisateur courant, base Tâches sans tâche non terminée, ou filtre de recherche trop restrictif — assorti de l'action correspondante (afficher aussi les tâches non assignées, ouvrir la base dans Notion, effacer la recherche) ; (c) lorsque Notion est injoignable, un message indiquant l'heure de la dernière synchronisation réussie, le cache restant consultable et utilisable pour démarrer une session.

**Sessions**

- **FR-016**: L'application MUST proposer deux modes de session : Pomodoro (durée fixe avec compte à rebours) et Tracker (durée libre avec chronomètre).
- **FR-017**: L'application MUST n'autoriser qu'une seule session active à la fois.
- **FR-018**: En mode Pomodoro, l'application MUST proposer des préréglages (25/5/15 et 50/10/20 minutes, pause longue après 4 pomodoros) et des valeurs personnalisées ; le mode Pomodoro MUST NOT proposer de pause manuelle en cours de session.
- **FR-019**: En mode Pomodoro, l'application MUST considérer localement la session comme allée à son terme quand le compte à rebours atteint zéro, et comme écourtée si elle est arrêtée avant, par l'utilisateur, par une mise en veille ou par un arrêt inopiné de l'application. Ce résultat MUST être écrit dans la propriété Statut de l'entrée de temps : « Complété » pour une session allée à son terme, « Écourté » pour une session écourtée (FR-026). Il pilote également la série de pomodoros (FR-020) et le commentaire de FR-026a, qui seul porte le motif précis de l'écourtement.
- **FR-020**: Après un pomodoro allé à son terme, l'application MUST proposer une pause (courte, ou longue tous les N pomodoros allés à leur terme consécutivement) ; une pause MUST NOT générer d'entrée de temps ; un pomodoro écourté MUST remettre à zéro le compteur de pomodoros consécutifs. Cette remise à zéro est une mécanique locale : elle découle du résultat de la session (FR-019) et non de la valeur écrite dans la propriété Statut. Le seul retranchement d'une durée d'inactivité sur un pomodoro allé à son terme MUST NOT remettre ce compteur à zéro.
- **FR-021**: En mode Tracker, l'application MUST permettre pause, reprise et arrêt ; la durée enregistrée MUST exclure les périodes de pause ; une mise en veille MUST mettre la session en pause.
- **FR-022**: L'application MUST persister l'état de la session courante localement à chaque transition, et MUST restaurer cet état au redémarrage selon les règles de l'US5.
- **FR-023**: L'application MUST ignorer (ne pas envoyer) toute session dont la durée effective est inférieure à 60 secondes, en informant l'utilisateur.
- **FR-024**: L'application MUST détecter l'inactivité (absence d'événements clavier/souris système) au-delà d'un seuil configurable (défaut 5 minutes), activée par défaut en mode Tracker et désactivée par défaut en mode Pomodoro, et MUST proposer de conserver ou retrancher la durée d'inactivité avant l'envoi de l'entrée. La durée envoyée à Notion est dans tous les cas la durée effectivement travaillée après retranchement, y compris lorsqu'elle est ainsi inférieure à la durée cible d'un pomodoro.
- **FR-025**: L'application MUST afficher dans la barre de menus l'état de la session : temps restant (Pomodoro) ou écoulé (Tracker), et un indicateur de pause ; au repos, uniquement l'icône.

**Entrées de temps**

- **FR-026**: À la fin de toute session éligible, l'application MUST créer exactement une entrée dans la base Time Entries avec : titre généré, relation vers la tâche, début, fin, durée en minutes, type (Pomodoro/Tracker), statut (« Complété » si la session est allée à son terme, « Écourté » si elle a été écourtée — voir FR-019), personne (utilisateur courant) et identifiant local unique.
- **FR-026a**: Le motif précis d'un écourtement (arrêt par l'utilisateur, mise en veille, arrêt inopiné de l'application) et, le cas échéant, la durée d'inactivité retranchée MUST être publiés en commentaire Notion sur la page de l'entrée ; ils MUST NOT faire l'objet d'une propriété de la base. Ce commentaire MUST être publié uniquement après la création réussie de la page. L'entrée MUST être considérée comme envoyée dès que la page existe : l'échec de la publication du commentaire MUST NOT remettre l'entrée en file d'attente ni empêcher son retrait de la file. L'application MUST NOT publier de commentaire pour une session allée à son terme sans retranchement. La requête de commentaire MUST être soumise au limiteur de débit de FR-029. L'intégration OAuth MUST déclarer la capacité d'insertion de commentaires dans le portail développeur Notion. Si `POST /v1/comments` répond `403`, l'application MUST en informer l'utilisateur une seule fois et continuer sans commentaire, l'entrée restant considérée comme envoyée.
- **FR-027**: L'application MUST stocker chaque entrée dans une file locale durable avant tentative d'envoi et MUST la retirer uniquement sur confirmation de succès.
- **FR-028**: L'envoi MUST être idempotent. La première tentative d'envoi d'une entrée MUST créer la page directement, sans vérification préalable. L'application MUST interroger la base Time Entries filtrée sur la propriété d'identifiant local (« ID » par défaut), et ne créer la page que si aucune entrée ne porte cet identifiant, uniquement avant un réessai qui fait suite à une tentative d'issue indéterminée : délai dépassé, coupure de connexion pendant la requête, ou absence de réponse. Un réessai qui fait suite à une réponse d'erreur explicite de Notion MUST NOT déclencher cette vérification, la réponse prouvant qu'aucune page n'a été créée. L'application MUST enregistrer localement l'issue de chaque tentative (aboutie, erreur explicite, indéterminée) afin de décider de cette vérification au réessai. Toute requête de vérification MUST être soumise au limiteur de débit de FR-029.
- **FR-029**: L'application MUST classer les échecs d'envoi en deux familles. Les erreurs transitoires (absence de réseau, délai dépassé, 429, 5xx) MUST être réessayées indéfiniment avec un délai croissant plafonné et MUST NOT conduire à abandonner l'entrée, quelle que soit la durée de l'indisponibilité ; l'application MUST respecter le `Retry-After` renvoyé par Notion. Les erreurs permanentes (400 de validation, 403 permissions retirées, 404 base ou tâche introuvable) MUST marquer l'entrée en échec définitif dès la première occurrence, sans réessai. Dans tous les cas, l'application MUST limiter son propre débit à 3 requêtes par seconde.
- **FR-030**: L'application MUST afficher le nombre d'entrées en attente et, pour une entrée en échec définitif, la cause et une action de résolution.
- **FR-031**: L'application MUST permettre de réassigner une entrée en échec à une autre tâche avant renvoi.

**Notifications et système**

- **FR-032**: L'application MUST émettre une notification système et un son (désactivables) à la fin d'un pomodoro et d'une pause.
- **FR-033**: L'application MUST proposer le lancement à l'ouverture de session (désactivé par défaut).
- **FR-034**: L'application SHOULD permettre d'activer un mode Concentration macOS pendant un pomodoro et de le désactiver à la fin, si l'utilisateur l'a autorisé.
- **FR-035**: L'application MUST empêcher l'exécution de plusieurs instances simultanées.
- **FR-036**: L'application MUST proposer l'interface en français par défaut, avec les chaînes externalisées.
- **FR-037**: L'application MUST tenir un journal local rotatif, de taille bornée, consignant les événements de session (transitions, démarrage, arrêt, veille, réveil, inactivité détectée), de synchronisation (rafraîchissement des tâches, tentatives d'envoi, réessais, issue de chaque tentative) et les erreurs rencontrées. Ce journal MUST NOT contenir de token, de code OAuth, ni de contenu de tâche au-delà de son identifiant. L'application MUST permettre de l'exporter depuis les réglages.

### Key Entities *(include if feature involves data)*

- **Connexion Notion** : le lien entre l'installation locale et un workspace Notion. Attributs : identifiant de workspace, nom et icône du workspace, identifiant de bot, identifiant et nom de l'utilisateur ayant autorisé, identifiant de page de template dupliquée (peut être vide), tokens (dans le Keychain uniquement). Une seule connexion à la fois.

- **Configuration des bases** : pour chaque rôle (Projets, Tâches, Time Entries), l'identifiant de la **base** conteneur, l'identifiant et le nom de la **source de données** qui porte effectivement le rôle, et le mapping nom → propriété. Une base Notion est un conteneur qui peut porter plusieurs sources ; c'est la source qui détient le schéma de propriétés, qui est interrogée et qui reçoit les pages créées. L'identifiant visible dans l'URL d'une base est celui du conteneur et ne suffit pas : les deux sont conservés, la source pour toutes les opérations, la base pour l'affichage, l'ouverture dans Notion et la re-résolution des sources. Partout ailleurs dans cette spécification, « base Tâches » ou « base Time Entries » désigne le rôle et donc la source qui lui est liée. Propriétés requises :
  - Tâches : Titre (title) ; Statut (status ou select) ; optionnels mappables : Personne (people), Projet (relation vers Projets).
  - Time Entries : Titre (title) ; Tâche (relation vers Tâches) ; Début (date) ; Fin (date) ; Durée (number, minutes) ; Type (select : Pomodoro, Tracker) ; Statut (select : Complété, Écourté) ; Personne (people) ; Identifiant local — nom par défaut « ID », type **rich text obligatoire** (pour l'idempotence). Cette propriété est écrite par l'application avec un identifiant qu'elle génère **avant** l'envoi. Ni une formule ni l'identifiant unique auto-incrémenté de Notion ne peuvent tenir ce rôle : leur valeur n'existe qu'après création de la page, donc trop tard pour servir de clé de déduplication. Le nom est remappable comme toute autre propriété (FR-007).
  - Projets (optionnel) : Titre (title).
  Le template fournit en plus des rollups Notion (temps total par tâche, par projet) que l'application ne lit pas.

- **Projet** : entrée de la base Projets, lue uniquement pour regrouper et afficher les tâches. Attributs : identifiant, titre.

- **Tâche** : entrée de la base Tâches. Attributs : identifiant, titre, statut, personnes assignées, projet lié, date de dernière utilisation locale (pour les récentes). Lue, jamais modifiée par l'application.

- **Session** : unité de travail locale en cours ou terminée. Attributs : identifiant local unique, tâche, mode (Pomodoro/Tracker), durée cible (Pomodoro), début, fin, durée effective, périodes de pause, périodes d'inactivité détectées, résultat (Allée à son terme/Écourtée/Ignorée) et cause d'écourtement (utilisateur, veille, arrêt inopiné). Le résultat détermine la valeur de la propriété Statut de l'entrée de temps (« Complété »/« Écourté ») et la remise à zéro de la série de pomodoros ; la cause d'écourtement reste locale et n'est publiée que dans le commentaire de FR-026a. Une session terminée éligible produit exactement une Entrée de temps.

- **Entrée de temps** : représentation locale d'une ligne de la base Time Entries. Attributs : ceux de FR-026 plus l'état d'envoi (en attente, envoyée, échec avec cause), le nombre de tentatives et la date de prochaine tentative.

- **Réglages** : durées et préréglages Pomodoro, nombre de pomodoros avant pause longue, seuils et activation de la détection d'inactivité par mode, notifications, son, lancement à l'ouverture de session, mode Concentration, intervalle de rafraîchissement des tâches, affichage des tâches non assignées, valeurs de statut considérées terminées.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Un nouvel utilisateur qui duplique le template passe de l'installation à sa première session démarrée en moins de 3 minutes, sans documentation.
- **SC-002**: Depuis un clic sur l'icône, un utilisateur ayant déjà travaillé sur la tâche démarre une session en moins de 5 secondes et au plus 3 clics.
- **SC-003**: Avec réseau, une entrée de temps est visible dans Notion moins de 10 secondes après la fin de la session dans 95 % des cas.
- **SC-004**: Sur 100 sessions terminées en conditions dégradées simulées (coupures réseau, limitation de débit, fermeture de l'app pendant la session), 100 entrées attendues arrivent dans Notion, aucune en double, aucune perdue.
- **SC-005**: La durée enregistrée d'une session diffère de la durée réelle mesurée de moins de 2 secondes, pauses et inactivité retranchée comprises.
- **SC-006**: Au repos (aucune session, menu fermé), l'application n'émet aucune requête réseau en dehors du rafraîchissement périodique des tâches et reste imperceptible pour l'utilisateur.
- **SC-007**: Un second membre du même workspace qui partage la page du template existant obtient une configuration valide sans saisir aucun identifiant.

## Assumptions

- Un seul workspace Notion par installation en v1 ; le multi-workspace est hors périmètre.
- Aucune notion d'équipe côté application en v1 : chaque membre fait sa propre autorisation OAuth ; les identifiants de workspace sont conservés localement pour une future logique de licence par workspace (v2).
- L'analyse du temps (répartition par projet, par tâche, par personne, par période) se fait dans Notion via les rollups et vues fournis par le template ; l'application n'offre aucun écran de statistiques.
- L'application ne crée, ne modifie ni ne clôture aucune tâche ; elle écrit uniquement dans la base Time Entries et, sur demande explicite, ajoute des propriétés manquantes aux bases.
- La détection d'inactivité repose uniquement sur le délai depuis le dernier événement d'entrée système ; aucune donnée sur les applications utilisées ou le contenu n'est collectée.
- Le template Notion (Projets, Tâches, Time Entries, relations et rollups) est un livrable du projet, maintenu dans un workspace public de l'éditeur et référencé dans la configuration de la connexion Notion.
- La distribution v1 se fait sous forme de bundle non signé à une équipe restreinte ; l'installation nécessite l'autorisation manuelle dans les réglages de sécurité macOS, documentée dans un guide d'installation.
- Le service serveur d'échange OAuth est hébergé sur Vercel. Le plan Hobby, seule offre gratuite, exclut l'usage commercial : cet écart est accepté pour la v1, dont la distribution est interne et non commerciale. Les fonctions restent écrites contre l'API HTTP standard, sans dépendance à une API propriétaire de la plateforme, et le passage en plan Pro ou la migration vers un autre hébergeur est un prérequis explicite de la v2 « licence par workspace ».
- Le journal local de FR-037 sert au diagnostic sur la machine de l'utilisateur uniquement : il n'est transmis nulle part automatiquement, et son export est une action manuelle de l'utilisateur.
- Le format des durées dans Notion est un nombre entier de minutes ; les secondes sont arrondies au plus proche.
