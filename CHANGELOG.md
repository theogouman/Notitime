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
- Icône dédiée dans la barre de menus, rendue en gabarit : elle se teinte avec
  le thème clair ou sombre et s'inverse quand le menu est ouvert.
- Pendant une session, l'icône reste affichée et le temps la suit — compte à
  rebours en Pomodoro, temps écoulé en suivi libre, chiffres à chasse fixe pour
  que rien ne se déplace de seconde en seconde.

### Sessions (US2, US4)

- Pomodoro à durée fixe et suivi libre à durée libre, sur une tâche choisie.
- Compte à rebours ou temps écoulé dans la barre de menus, avec le nom court de
  la tâche.
- Pause et reprise en suivi libre ; le Pomodoro n'en propose pas en cours de
  session, mais propose une pause après coup, courte ou longue selon la série.
- Une session de moins d'une minute n'est pas enregistrée, et le dit.
- Son de fin de session, et notification système lorsque macOS l'autorise.

### Entrées de temps (US2, US6)

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
