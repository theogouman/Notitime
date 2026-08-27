# Phase 0 — Recherche et décisions techniques

**Feature**: 001-notion-time-tracker | **Date**: 2026-08-27

Chaque entrée suit le format Décision / Justification / Alternatives écartées. Les points marqués **À VÉRIFIER** doivent être confrontés à la documentation Notion en vigueur au moment d'écrire le code : ce sont des choix structurants dont le détail exact ne peut pas être figé depuis ce plan.

---

## R-01 — Version de l'API Notion et découpage bases / sources de données

**Décision** (tranchée, vérifiée contre la documentation officielle le 2026-08-27) : épingler `Notion-Version: 2026-03-11` dans une constante unique de `NotitimeCore/Notion/NotionAPI.swift`, et écrire tout le client contre le modèle **source de données** introduit par la version `2025-09-03`.

**Ce que le modèle change, concrètement.** Depuis `2025-09-03`, une base Notion est un conteneur qui peut porter plusieurs sources de données. C'est la source, et non la base, qui porte le schéma de propriétés et qui est interrogeable. L'identifiant visible dans l'URL d'une base est celui du conteneur : il ne suffit pas à interroger quoi que ce soit. Une intégration restée sur `2022-06-28` fonctionne tant que chaque base connectée n'a qu'une source, et **casse dès qu'une base en acquiert une seconde** — un mode de défaillance différé, déclenché par une action côté Notion et non par un déploiement, donc particulièrement mauvais à découvrir en production.

**Pourquoi `2026-03-11` et non `2025-09-03`.** C'est la version stable la plus récente. Elle n'introduit que trois ruptures par rapport à `2025-09-03`, dont une seule nous concerne : le champ `archived` est renommé `in_trash` sur les pages, bases, blocs et sources de données ; `archived` subsiste comme alias déprécié. Les deux autres — le paramètre `after` de l'ajout de blocs enfants remplacé par un objet `position`, et le type de bloc `transcription` renommé `meeting_notes` — portent sur des surfaces que l'application n'utilise pas. Épingler la version la plus récente évite une migration supplémentaire dans les mois qui viennent, à coût nul aujourd'hui.

**Correspondance endpoint par rôle** (méthodes et chemins vérifiés) :

| Rôle | Appel |
|---|---|
| Résoudre les sources d'une base | `GET /v1/databases/{database_id}` → champ `data_sources[]`, chaque élément portant `id` et `name` |
| Lire le schéma | `GET /v1/data_sources/{data_source_id}` → champ `properties` |
| Interroger | `POST /v1/data_sources/{data_source_id}/query`, corps `filter` / `sorts` / `start_cursor` / `page_size`, pagination par `has_more` et `next_cursor` |
| Créer une page | `POST /v1/pages` avec `parent: { "type": "data_source_id", "data_source_id": "..." }` |
| Ajouter une propriété manquante | `PATCH /v1/data_sources/{data_source_id}`, corps `properties` |
| Lister les sources accessibles | `POST /v1/search` avec `filter: { "property": "object", "value": "data_source" }` |
| Publier un commentaire | `POST /v1/comments` avec `parent: { "page_id": "..." }` et `rich_text` |

Deux conséquences à ne pas manquer. D'abord, `POST /v1/search` n'accepte plus `"database"` comme valeur de filtre : il retourne des objets `data_source`, chacun portant `parent.database_id` (la base conteneur) et `database_parent` (le parent de cette base). L'écran d'assignation des rôles liste donc naturellement des sources, et remonte à la base par ce champ. Ensuite, pour les propriétés de type relation, une requête sous `2025-09-03` et au-delà doit ne contenir **que** `data_source_id` — fournir `database_id` est refusé — même si les réponses portent désormais les deux.

**Base à plusieurs sources.** L'application ne choisit pas à la place de l'utilisateur et n'échoue pas : quand une base assignée expose plusieurs sources, elle les présente et demande laquelle porte le rôle. Voir le cas limite correspondant dans la spec et la règle de validation dans `data-model.md`.

**Sources** : [guide de migration 2025-09-03](https://developers.notion.com/docs/upgrade-guide-2025-09-03), [versionnement](https://developers.notion.com/reference/versioning), [guide de migration 2026-03-11](https://developers.notion.com/docs/upgrade-guide-2026-03-11), [interroger une source](https://developers.notion.com/reference/query-a-data-source), [mettre à jour une source](https://developers.notion.com/reference/update-a-data-source), [objet source de données](https://developers.notion.com/reference/data-source), [rechercher](https://developers.notion.com/reference/post-search), [créer un commentaire](https://developers.notion.com/reference/create-a-comment).

**Alternatives écartées** : rester sur `2022-06-28` (rejeté : casse dès qu'une base connectée acquiert une seconde source, sans qu'aucun déploiement ne l'ait déclenché) ; épingler `2025-09-03` (rejeté : impose une migration supplémentaire à brève échéance pour aucun gain, les ruptures de `2026-03-11` ne nous touchant qu'en renommant `archived` en `in_trash`) ; suivre automatiquement la dernière version (rejeté : la constitution exige une constante figée, et une bascule silencieuse casserait le mapping).

## R-02 — Horloge des sessions

**Décision**: mesurer les durées avec `ContinuousClock` (temps monotone qui continue de courir pendant la veille), stocker début et fin en UTC avec `Date`, et faire de la veille un événement explicite de la machine à états plutôt qu'un effet de l'horloge.

**Justification**: la spec exige des durées insensibles aux changements d'horloge (fuseau, heure d'été, NTP), ce qu'aucune arithmétique sur `Date` ne garantit. Elle exige aussi que la veille arrête un pomodoro et mette un tracker en pause, avec une date de fin à l'instant de la veille : ce comportement doit venir de la notification de veille, pas d'un choix d'horloge implicite. `ContinuousClock` donne une base monotone lisible ; l'écart tolérable est de 2 s (SC-005), très au-dessus de sa précision.

**Alternatives écartées**: `SuspendingClock`, qui s'arrête pendant la veille (rejeté : masque la veille au lieu de la rendre explicite, et rend l'horodatage de fin ambigu) ; différences de `Date` (rejeté : un ajustement NTP fausserait la durée, ce que la spec interdit).

---

## R-03 — Détection d'inactivité

**Décision**: interroger `CGEventSource.secondsSinceLastEventType` sur l'état de session combiné, pour tout type d'événement d'entrée, par sondage à basse fréquence (une fois toutes les 15 s) pendant une session seulement, derrière le protocole `InactivityMonitor` de Core.

**Justification**: cette API renvoie un simple délai depuis le dernier événement, sans jamais exposer le contenu des frappes, l'application au premier plan ni l'écran — exactement la contrainte de vie privée de la constitution, et elle ne demande aucune autorisation d'accessibilité. Un sondage à 15 s suffit pour un seuil par défaut de 5 minutes et reste imperceptible. Le protocole permet de tester les scénarios d'inactivité avec une sonde simulée, sans machine réelle.

**À VÉRIFIER**: la combinaison exacte de source d'événement et de type « n'importe quel événement » à passer à l'appel, et son comportement quand l'écran est verrouillé ou une session utilisateur commutée.

**Alternatives écartées**: un moniteur d'événements global `NSEvent` (rejeté : demande l'autorisation d'accessibilité et observe réellement les frappes, contraire à la constitution) ; l'API `IOKit` d'inactivité (rejeté : plus bas niveau sans bénéfice ici).

---

## R-04 — Veille, réveil et arrêt de session

**Décision**: observer `NSWorkspace.willSleepNotification` et `didWakeNotification` depuis `App/System/WorkspaceSleepObserver.swift`, et les traduire en événements `.systemWillSleep` / `.systemDidWake` de la machine à états de Core. La transition provoquée par la veille est persistée avant que le système ne s'endorme.

**Justification**: `willSleepNotification` est délivrée avant la mise en veille, ce qui laisse le temps d'horodater la fin et d'écrire l'état — indispensable pour dater l'arrêt « à l'instant de la veille ». La machine à états ne connaît que des événements nommés, ce qui rend les scénarios 3 et 4 de l'US5 testables sans endormir une machine.

**À VÉRIFIER**: le budget de temps réellement accordé au traitement de `willSleepNotification`, et le comportement en veille brutale (batterie vide) — dans ce cas seul le mécanisme de reprise après arrêt inopiné s'applique.

**Alternatives écartées**: détecter la veille après coup par un saut d'horloge au réveil (rejeté : ne permet pas de dater la fin correctement et confond veille et suspension de processus).

---

## R-05 — Limiteur de débit et respect de `Retry-After`

**Décision**: un acteur `RateLimiter` unique dans Core, seau à jetons de 3 jetons par seconde, traversé par **toutes** les requêtes Notion sans exception — lecture des tâches, vérification d'idempotence, création de page, publication de commentaire. Sur `429`, la valeur de `Retry-After` suspend le seau entier, pas seulement la requête fautive.

**Justification**: la limite Notion s'applique à l'intégration, pas à un appel : ne limiter que la file d'envoi laisserait le rafraîchissement des tâches déclencher des `429` pendant un envoi. Un acteur unique donne un point d'application unique et vérifiable. Suspendre le seau entier évite qu'une requête concurrente reparte immédiatement dans le mur.

**Alternatives écartées**: un limiteur par sous-système (rejeté : ne respecte pas la limite globale) ; s'en remettre aux seuls réessais sur `429` (rejeté : la constitution impose un limiteur côté client).

---

## R-06 — Idempotence et suivi de l'issue des tentatives

**Décision**: chaque entrée de la file porte un `attemptOutcome` persistant à trois valeurs — `jamaisTentée`, `erreurExplicite`, `indéterminée`. La création est directe si l'issue précédente est `jamaisTentée` ou `erreurExplicite` ; elle est précédée d'une recherche par identifiant local si elle est `indéterminée`. L'issue est écrite **avant** l'envoi (`indéterminée` par défaut) et corrigée à réception de la réponse.

**Justification**: c'est la traduction exacte de FR-028. Écrire `indéterminée` avant l'appel est le point critique : si le processus meurt pendant la requête, l'état persistant dit déjà qu'on ne sait pas, et le réessai vérifiera. Écrire l'issue après coup laisserait une fenêtre où un crash produirait un doublon. Une erreur HTTP explicite de Notion prouve qu'aucune page n'a été créée et dispense de la vérification, ce qui garde le cas nominal à une requête.

**Alternatives écartées**: vérification systématique (rejeté par la clarification : double le coût API de chaque envoi) ; en-tête d'idempotence côté Notion (rejeté : l'API n'en offre pas de garantie contractuelle).

---

## R-07 — Stockage des tokens

**Décision**: `kSecClassGenericPassword`, un item pour l'`access_token` et un pour le `refresh_token`, attribut d'accessibilité `kSecAttrAccessibleAfterFirstUnlock`, service nommé d'après le bundle identifier `com.notitime.app`. Accès derrière le protocole `TokenStore` de Core, implémenté dans `App/System/KeychainTokenStore.swift`.

**Justification**: `AfterFirstUnlock` permet à la file d'envoi de repartir après un redémarrage sans interaction, tout en gardant les tokens chiffrés au repos. Le protocole permet de tester la logique de rafraîchissement et de déconnexion avec un magasin en mémoire, sans toucher au trousseau de la machine de test.

**Alternatives écartées**: `kSecAttrAccessibleWhenUnlocked` (rejeté : bloquerait la reprise de la file tant que l'utilisateur n'a pas déverrouillé) ; un fichier chiffré maison (rejeté : la constitution impose le Keychain).

---

## R-08 — SwiftData dans un package et cloisonnement du magasin

**Décision**: déclarer les modèles SwiftData dans `NotitimeCore/Persistence`, exposer un `ModelContainer` construit par Core, et permettre aux tests d'en obtenir un en mémoire. Un seul magasin dans Application Support, jamais de token dedans.

**Justification**: garder les modèles dans Core est ce qui rend la file d'envoi et la restauration de session testables par `swift test`. Le conteneur en mémoire donne des tests hermétiques et rapides, sans fichier résiduel.

**À VÉRIFIER**: le comportement de SwiftData sous concurrence entre l'acteur d'envoi et l'interface, et la stratégie de migration légère à adopter dès la v1 pour ne pas se fermer la porte.

**Alternatives écartées**: SQLite via `libsqlite3` (rejeté : plus de code à écrire pour un besoin que SwiftData couvre, contraire au principe V) ; modèles dans la cible applicative (rejeté : rendrait la file non testable hors Xcode).

---

## R-09 — Tests du client Notion sur réponses enregistrées

**Décision**: `HTTPTransport` est un protocole de Core ; les tests fournissent une implémentation qui rejoue des fixtures JSON depuis `Tests/NotitimeCoreTests/Fixtures/`, indexées par méthode et chemin. La cible applicative fournit l'implémentation `URLSession`. Les fixtures couvrent au minimum : schéma de base valide, schéma incomplet, page de tâches paginée, création d'entrée réussie, `429` avec `Retry-After`, `401`, `404`, et corps d'erreur de validation.

**Justification**: la constitution interdit d'appeler l'API réelle en CI. Passer par un protocole plutôt que par un `URLProtocol` enregistré globalement garde les tests parallélisables et sans état global.

**Alternatives écartées**: `URLProtocol` custom enregistré sur la configuration de session (rejeté : état global, tests moins isolés) ; enregistrement/rejeu automatique type VCR (rejeté : dépendance tierce interdite).

---

## R-10 — Instance unique

**Décision**: au lancement, chercher une autre instance du même bundle identifier avec `NSRunningApplication`; si elle existe, activer l'instance en place, afficher un message bref et quitter.

**Justification**: satisfait FR-035 sans fichier verrou à nettoyer après un crash. Activer l'instance existante est le comportement attendu quand l'utilisateur relance l'app parce qu'il ne l'a pas vue dans la barre de menus.

**Alternatives écartées**: fichier verrou (rejeté : reste après un arrêt inopiné et bloque le relancement) ; port ou socket local (rejeté : ouvre une écoute réseau, contraire au choix OAuth et au principe I).

---

## R-11 — Lancement à l'ouverture de session

**Décision**: `SMAppService.mainApp.register()` / `.unregister()`, l'état du réglage étant lu depuis `SMAppService.mainApp.status` plutôt que depuis une préférence locale.

**Justification**: API supportée depuis macOS 13, sans agent de lancement séparé ni entitlement supplémentaire — cohérent avec « pas de processus annexes ». Lire l'état réel évite qu'une case cochée mente après une désactivation faite par l'utilisateur dans les Réglages Système.

**Alternatives écartées**: `LSSharedFileList` (déprécié) ; `LaunchAgent` déposé dans `~/Library/LaunchAgents` (rejeté : processus annexe et fichier à maintenir).

---

## R-12 — Mode Concentration

**Décision**: traiter le mode Concentration comme strictement optionnel (FR-034 est un SHOULD). L'app déclenche un raccourci Shortcuts nommé, que l'utilisateur crée lui-même et désigne dans les réglages ; si le raccourci est absent ou échoue, la session démarre quand même et l'app le signale une seule fois.

**Justification**: macOS n'expose aucune API publique pour activer un mode Concentration. Passer par Shortcuts est le seul chemin sanctionné, et il place la configuration chez l'utilisateur, qui garde le contrôle des autorisations. Faire dépendre le démarrage d'une session de ce mécanisme serait une régression fonctionnelle inacceptable.

**À VÉRIFIER**: le mécanisme d'invocation retenu (URL `shortcuts://run-shortcut` ou exécution de l'outil en ligne de commande) et ses implications d'entitlement pour un bundle non signé.

**Alternatives écartées**: écriture directe dans les préférences de Concentration (rejeté : privé, fragile, casserait à la première mise à jour système) ; AppleScript (rejeté : demande l'autorisation d'automatisation pour un gain nul).

---

## R-13 — Journal local rotatif

**Décision**: double sortie. `os.Logger` pour le diagnostic en direct via la Console, et un fichier `Application Support/Notitime/Logs/notitime.log` en rotation sur deux fichiers de 2 Mo maximum, écrit par un acteur dédié de Core. Les valeurs sensibles ne sont jamais passées au journal : les tokens, codes et verifiers ne franchissent pas la frontière de la fonction qui les manipule, et une tâche n'est journalisée que par son identifiant.

**Justification**: `os.Logger` seul ne satisfait pas FR-037, qui exige un export depuis les réglages. Un plafond de 4 Mo au total est largement suffisant pour diagnostiquer un incident de synchronisation et reste négligeable sur disque. Confier l'écriture à un acteur évite l'entrelacement des lignes sous concurrence.

**Alternatives écartées**: export via `OSLogStore` (rejeté : l'accès aux archives système est restreint et fragile pour un bundle non signé) ; journal en base SwiftData (rejeté : mélange le diagnostic et les données métier, et alourdit le magasin).

---

## R-14 — Génération du projet, build et distribution

**Décision**: `project.yml` XcodeGen versionné, `.xcodeproj` en `.gitignore`, `scripts/generate.sh` puis `scripts/build.sh` et `scripts/test.sh` autour de `xcodebuild`. Binaire universel `arm64` + `x86_64`. Bundle non signé en v1, entitlements minimaux, aucune sandbox contournée.

**Justification**: reprend littéralement le principe VI. Garder les entitlements minimaux dès maintenant est ce qui rendra la signature Developer ID et la notarisation possibles plus tard sans retouche d'architecture.

**Alternatives écartées**: `.xcodeproj` versionné (rejeté : le principe VI l'interdit) ; Swift Package Manager seul pour produire le bundle applicatif (rejeté : ne produit pas de `.app` avec `Info.plist`, ressources et scheme d'URL sans contorsions).

---

## R-15 — Découverte des bases après duplication du template

**Décision**: quand l'autorisation renvoie un `duplicated_template_id`, parcourir les blocs enfants de cette page pour y relever les blocs `child_database`, résoudre chacun par `GET /v1/databases/{id}` pour obtenir ses `data_sources[]`, lire le schéma de chaque source par `GET /v1/data_sources/{id}`, puis assigner les rôles **par validation de schéma** — la source qui satisfait le schéma Time Entries prend ce rôle, etc. — et non par correspondance de titre. En l'absence de template dupliqué, lister les sources accessibles par `POST /v1/search` filtré sur `data_source` et pré-sélectionner celles dont le schéma correspond, l'utilisateur tranchant. Dans les deux cas, l'unité assignée à un rôle est une **source**, jamais une base ; la base conteneur est retenue en plus, via `parent.database_id`.

**Justification**: les titres sont traduisibles et renommables par l'équipe, le schéma beaucoup moins. Piloter la découverte par le schéma rend le cas « second membre du workspace qui partage la page existante » (SC-007) automatique, et donne un diagnostic utile quand la validation échoue.

**Alternatives écartées**: correspondance par titre (rejeté : casse dès qu'une base est renommée, ce que la spec liste explicitement comme cas limite) ; identifiants de bases codés en dur depuis le template public (rejeté : chaque duplication crée de nouveaux identifiants) ; supposer une source unique par base (rejeté : produit un échec obscur sur les bases multi-sources, que la spec traite désormais par un choix explicite de l'utilisateur).

---

## Points laissés au découpage en tâches

- Stratégie de purge du cache de tâches quand une tâche disparaît de Notion sans être terminée.
- Contenu précis des messages d'état du menu (FR-015a), qui relève des chaînes localisées.
