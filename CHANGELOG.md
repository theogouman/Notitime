# Journal des modifications

Comportements visibles par l'utilisateur, dans l'ordre des livraisons.

## Non publié

### Connexion et configuration (US1)

- Connexion à Notion par OAuth, le secret client restant sur le service serveur.
- Reconnaissance automatique des trois bases après duplication du template,
  y compris lorsqu'elles sont rangées dans une sous-page.
- Reconnaissance par schéma et non par nom : une base renommée reste reconnue,
  et les noms du template diffusé (« Status », « Date de début », « Méthode »)
  sont compris au même titre que ceux de la documentation.
- Changer la base Tâches prend effet immédiatement. Le cache des tâches était
  bâti au premier chargement puis réutilisé jusqu'à la fermeture : une base
  changée depuis les réglages, par une reconnexion ou par une revalidation ne
  l'atteignait pas, et il interrogeait l'ancienne. Sans erreur, sans tâche, et
  avec une liaison pourtant correcte. Le journal nomme désormais la base
  interrogée à chaque rafraîchissement.
- Les tâches se chargent dès que la connexion Notion aboutit, sans attendre
  l'ouverture du menu ni un relancement.
- La liste des modèles d'une base est enfin lue correctement : cet endpoint ne
  suit pas l'enveloppe habituelle de l'API, et la réponse était rejetée — ce qui
  passait pour une base sans modèle de page.
- Le modèle de page par défaut de la base Time Entries est reconstaté à chaque
  lancement, et plus seulement à la liaison : une base liée avant que Notitime
  ne sache le lire créait ses entrées nues, sans que rien ne le dise. Le journal
  indique désormais, pour chaque entrée, si elle est née d'un modèle.
- Changer une base depuis les réglages ouvre une fenêtre de choix pour ce rôle
  précis. Le bouton unique d'autrefois basculait tout l'onglet Connexion sur
  l'écran de désignation manuelle, où le premier clic réassignait une base à un
  rôle qu'on n'avait pas choisi.
- « Revalider » dit son résultat dans les réglages au lieu de déplacer
  l'utilisateur vers un autre onglet.
- Les statuts considérés terminés sont lus dans la base — le groupe « terminé »
  de la propriété, quels que soient ses libellés — au lieu d'être devinés. Le
  réglage ne sert plus qu'à en ajouter d'autres, et un statut inconnu de la base
  est ignoré au lieu de faire échouer le chargement des tâches.
- Désignation manuelle des bases quand la détection ne trouve rien, avec une
  explication et un recours à chaque étape plutôt qu'un écran vide.
- Connexion et réglages dans une fenêtre dédiée ; le menu reste réservé à
  l'usage quotidien.

### Présentation

- Icône d'application, dans le Dock, le Finder et la fenêtre « À propos ».
- Icône de la barre de menus recadrée sur la silhouette et portée à 20 pt : elle
  n'occupait auparavant que les trois quarts de sa hauteur, et paraissait petite.
- Icône dédiée dans la barre de menus, rendue en gabarit : elle se teinte avec
  le thème clair ou sombre et s'inverse quand le menu est ouvert.
- Pendant une session, l'icône reste affichée et le temps la suit — compte à
  rebours en Pomodoro, temps écoulé en suivi libre, chiffres à chasse fixe pour
  que rien ne se déplace de seconde en seconde.
- Dans le menu, le temps change chiffre par chiffre : seuls les chiffres qui
  bougent glissent, vers le bas en Pomodoro, vers le haut en suivi libre.
- Les attentes réseau — autorisation, détection des bases, chargement des tâches
  — s'annoncent par un titre en grand, centré, qui scintille, au lieu d'une
  molette accompagnée d'une ligne en petit.
- L'icône du workspace Notion ne surgit plus une fois téléchargée : un squelette
  occupe sa place, bat une fois, puis lui cède par un fondu croisé.
- Ces trois animations s'effacent quand le système demande moins de mouvement.
- Aucune méthode n'est présélectionnée à l'ouverture du panneau : la
  précédente y restait active, ce qui donnait un choix déjà fait alors qu'on
  vient justement le faire. Les durées de Pomodoro se colorent de la teinte
  d'accent du système sous le curseur.
- La demande d'autorisation du navigateur s'attache à la fenêtre de
  configuration. Elle se posait auparavant au petit bonheur : l'ancre fournie
  pouvait être le popover du menu, en train de se fermer, ou une fenêtre
  fantôme jamais affichée.
- Le choix de la méthode se fait sur deux cartes côte à côte — Pomodoro et
  Suivi libre — sous le titre « Comment veux-tu travailler ? ». Survoler
  Pomodoro fait passer sa carte au second plan et découvre ses trois durées,
  cliquables sur place. Suivi libre porte l'icône du réveil.
- L'emplacement dans la barre de menus a une largeur fixe : il ne se réajuste
  plus au démarrage et à l'arrêt d'une session.
- L'anneau bleu du champ de recherche ne traverse plus la transition vers le
  panneau de méthode : le champ rend le focus avant qu'elle ne commence.
- Une session Pomodoro et une pause s'affichent sur un cadran : anneau qui se
  rétracte, heure de sonnerie et temps restant au centre. Le suivi libre garde
  son seul compteur — il n'a pas d'échéance à promettre.
- « Réglages » et « Quitter » sont repliés derrière un bouton en points de
  suspension, au bas du menu.
- Le menu n'annonce plus le workspace relié à chaque ouverture : c'est une
  information de réglages.
- L'anneau bleu du champ de recherche ne reste plus affiché autour de l'en-tête
  après le choix d'une tâche.

### Premier lancement

- Accueil en quatre écrans, dans une fenêtre large et centrée, au tout premier
  lancement : le récit — texte qui se dépose mot à mot, avatar incrusté dans la
  phrase, promesses en pastilles —, le template offert et sa grille de
  présentation, les deux façons de connecter Notion, puis la lecture des bases
  détectées, changeables sur place. Il ne se joue qu'une fois.
- Terminer l'accueil ferme la fenêtre et ouvre le menu, tâches déjà chargées.
- Écran d'accueil : logo de l'application, nom, ce qu'elle fait, et un seul
  bouton — « Connecter mon Notion », portant le logo Notion.
- Cet écran s'ouvre de lui-même au premier lancement et après une déconnexion :
  il n'y avait jusqu'ici rien à faire dans le menu, sans que rien ne le dise.
- Clic droit sur l'icône de la barre de menus : Réglages, À propos, Quitter.
- Le menu de la barre de menus propose exactement la même chose que la fenêtre
  quand aucun compte n'est relié : le logo, le titre, la description et le bouton
  de connexion. Il laissait auparavant démarrer une session après une
  déconnexion — les liaisons survivent à celle-ci, et passaient pour une
  configuration valide.

### Réglages

- « Se déconnecter » depuis les réglages, qui ramène à l'écran d'accueil.
- Changer une base liée ouvre une fenêtre de choix par-dessus les réglages, au
  lieu de remplacer l'écran par une désignation dont on ne pouvait plus sortir —
  ni se déconnecter, ni revenir, ni changer quoi que ce soit.
- Section « Connexion » remaniée : le nom du workspace en titre, son icône —
  emoji comme image —, la date de connexion, et les bases liées présentées en
  tableau, chacune modifiable depuis sa ligne.

### Sessions (US2, US4)

- Démarrage en deux temps, sans changer d'écran : la liste de tâches se replie
  quand on en choisit une, et le choix de la méthode s'ouvre sous son nom —
  durées de pomodoro d'un côté, suivi libre de l'autre. Le chevron, un clic sur
  l'en-tête ou la touche Échap ramènent à la liste, la recherche intacte.
- La dernière méthode lancée est mise en avant et se déclenche à la touche
  Entrée : reprendre une tâche familière tient en deux clics.
- Les flèches parcourent la liste, Entrée déplie la tâche visée.
- Réassigner une entrée en échec se fait depuis sa propre liste déroulante, et
  ne dépend plus de la tâche sélectionnée ailleurs dans le menu.

- Pomodoro à durée fixe et suivi libre à durée libre, sur une tâche choisie.
- Compte à rebours ou temps écoulé dans la barre de menus, avec le nom court de
  la tâche.
- Pause et reprise en suivi libre ; le Pomodoro n'en propose pas en cours de
  session, mais propose une pause après coup, courte ou longue selon la série.
- Une session de moins d'une minute n'est pas enregistrée, et le dit.
- Son de fin de session, et notification système lorsque macOS l'autorise.

### Interruptions (US5)

- Détection des suspensions par saut d'horloge : si plus de trente secondes
  s'écoulent entre deux battements du minuteur, le temps non travaillé est
  retranché d'un suivi libre et un pomodoro est clos à son dernier instant connu.
  Jusque-là, une veille non annoncée par le système — clapet fermé avec un écran
  externe, par exemple — était comptée comme du temps de travail.
- Le journal consigne tous les événements système observés : veille, réveil,
  veille des écrans, verrouillage, changement d'utilisateur, extinction, en
  indiquant pour chacun s'il est traité ou seulement constaté.

### Entrées de temps (US2, US6)

- Les entrées naissent du **modèle de page par défaut** de la base Time Tracker,
  quand elle en déclare un : la page créée porte le contenu prévu par le modèle,
  et plus seulement ses propriétés.

- La méthode et le statut écrits dans Time Tracker sont projetés sur les options
  réelles de la base : « Time Tracker » plutôt qu'une option « Tracker » créée
  au passage, « Terminée » plutôt que « Complété ». Quand aucune option ne
  convient à un statut, la propriété est omise et le journal l'explique — une
  entrée sans statut vaut mieux qu'une entrée refusée.

- Chaque session éligible produit une entrée dans la base Time Entries : titre
  généré, tâche liée, début, fin, durée, méthode, statut et responsable.
- Le statut s'adapte aux valeurs réellement présentes dans la base.
- Rien n'est perdu : les entrées non parties restent en file et repartent au
  retour du réseau, au lancement suivant, ou à la demande.
- Rien n'est dupliqué : après une coupure d'issue incertaine, l'entrée est
  recherchée avant d'être recréée, corbeille comprise.
- Une entrée définitivement refusée est conservée, sa cause affichée, et peut
  être réassignée à une autre tâche avant renvoi.

### Choix de la tâche (US3)

- Liste filtrée sur les tâches non terminées, assignées à l'utilisateur, avec
  les tâches récemment utilisées en tête.
- Recherche instantanée, insensible à la casse et aux accents, sans requête.
- Liste vide toujours expliquée, avec l'action qui permet d'en sortir.
- Notion injoignable : les tâches restent consultables, avec l'heure de la
  dernière synchronisation réussie.

### Interruptions (US5)

- Mise en veille : un pomodoro est clôturé à l'instant de la veille, un suivi
  libre est mis en pause.
- Arrêt inopiné : un pomodoro retrouvé est clôturé au dernier instant connu, un
  suivi libre est présenté en pause.
- Inactivité détectée : Notitime demande de conserver ou de retrancher, et ne
  tranche jamais seul. Activée par défaut en suivi libre, désactivée en Pomodoro.
- Quitter pendant une session demande confirmation et clôture proprement.

### Réglages (US7)

- Durées, préréglages 25/5/15 et 50/10/20, valeurs personnalisées.
- Détection d'inactivité par mode et seuil.
- Notifications, son, intervalle de rafraîchissement, tâches non assignées,
  statuts considérés terminés.
- Lancement à l'ouverture de session, mode Concentration par raccourci.
- Changement des bases liées avec revalidation, et export du journal.

### Limites connues

- Le bundle n'est pas signé par un identifiant de développeur : macOS demande
  une autorisation manuelle à la première ouverture, redemande l'accès au
  trousseau après chaque mise à jour, et peut refuser les notifications.
