# Journal des modifications

Comportements visibles par l'utilisateur, dans l'ordre des livraisons.

## Non publié

### Connexion et configuration (US1)

- L'icône du workspace ne se recharge plus en passant d'un onglet à l'autre :
  déjà lue, elle est là dès le premier rendu. Le squelette et son fondu sont
  réservés à une vraie attente.
- La fenêtre s'appelle « Réglages de Notitime », mesure 800 × 600 et ne se
  redimensionne plus. Ses deux onglets sont dessinés plutôt que confiés à
  AppKit — qui n'en retenait que le texte et l'icône, dans cet ordre : le logo
  Notion suit désormais « Connexion Notion », et l'engrenage « Réglages ».
- D'un onglet à l'autre, la pastille active glisse — position et largeur — au
  lieu d'apparaître sous le nouveau nom.
- Une seule échelle typographique pour toute la fenêtre : six tailles nommées,
  et des boutons tous de même hauteur. « Je ne trouve pas ma base de données »
  était écrit plus petit que « Fermer », juste à côté.
- La feuille de choix d'une base a deux pages. Sur la liste, « Recharger » est
  devenu une icône à droite de la recherche, et sa place en bas revient à
  « Je ne trouve pas ma base de données » : à cet endroit, la question n'est
  pas de relire la liste mais de comprendre pourquoi la base n'y est pas.
- Ce bouton ouvre un guide : la manipulation filmée dans Notion, en boucle et
  sans son, la marche à suivre citée avec les commandes telles qu'elles
  apparaissent à l'écran, puis « Ouvrir Notion » — l'application si elle est
  installée, le site sinon — et « C'est fait », qui relance la recherche et
  ramène à la liste. La feuille garde la même taille d'une page à l'autre : le
  guide entre par la droite, la liste revient par la gauche.
- Tant que la feuille de choix reste ouverte — liste ou guide —, les bases
  accessibles sont relues chaque seconde, et deux fois par seconde pendant les
  vingt secondes qui suivent « C'est fait ». Une base partagée dans Notion
  apparaît d'elle-même, sans rien redemander.
- Une base ne disparaît plus de la liste entre deux relectures. La recherche de
  Notion n'est pas stable d'un appel à l'autre — le même espace a renvoyé neuf
  sources, puis trois, puis neuf à nouveau, sans que rien n'ait changé : ce qui
  a été vu il y a moins d'une minute reste affiché le temps qu'elle se reprenne.
- La fenêtre des réglages met l'application dans le Dock tant qu'elle est
  ouverte, et l'en retire à sa fermeture : une fenêtre passée derrière une autre
  n'avait plus de porte pour y revenir.
- Le journal ne note plus qu'un changement de la liste des bases, au lieu d'une
  ligne par relecture qui chassait tout le reste.
- Pendant une recherche, la liste disparaît au profit d'un titre qui scintille,
  « On cherche tes bases de données » : une liste qui se complète sous les yeux
  se lit comme une liste complète. Elle revient en fondu, et les bases
  nouvellement trouvées clignotent deux fois, brièvement.
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

- Les messages de l'application ne s'installent plus dans le panneau : ils
  s'affichent dans une carte, sous le menu, et s'effacent d'eux-mêmes au bout de
  quelques secondes — plus longtemps pour les phrases longues. « 5 min
  d'inactivité détectées » restait jusqu'ici affiché sur tous les écrans, bien
  après le fait qu'il annonçait. La carte vit hors du menu : elle reste lisible
  quand celui-ci se referme, et ne lui vole jamais le premier plan.
- L'ombre de la carte ne se coupe plus net sur une arête : sa fenêtre lui laisse
  la place de se fondre, et deux ombres — une courte qui la pose, une longue et
  diffuse qui la fait flotter — remplacent le halo gris d'avant.
- La carte descend de sous le menu en fondu et repart par où elle est venue,
  reprend exactement la largeur et le bord du menu ouvert, et porte sur sa
  tranche supérieure une fine bande qui se vide : on voit le temps qu'il reste
  avant qu'elle ne s'en aille.
- Les messages parlent comme on parle : « La session était trop courte, ça n'a
  pas été enregistré dans Notion », « Bravo, les 25 min de pomodoro sont
  atteints », « La pause est terminée, on reprend ? », « Tu dois d'abord
  sélectionner une tâche », « Une session est déjà en cours, impossible de
  cumuler », « Impossible de mettre en pause un pomodoro ».
- Ce que la liste de tâches a à dire d'elle-même — vide, filtrée, ou synchronisée
  à telle heure — reste dans la liste : c'est un état, pas une annonce.
- Ouvrir les réglages depuis le menu referme le menu : la fenêtre passait
  devant, le panneau restait derrière, et il fallait un clic de plus pour s'en
  débarrasser.
- Le panneau est collé au bord droit de l'écran, quel que soit l'écran affiché.
  Laissé au système, il se plaçait sous l'icône : la liste, plus large, débordait
  vers la gauche, le compteur restait à droite, et passer de l'un à l'autre
  donnait un mouvement de biais au lieu d'un changement de taille. Le coin haut
  et droit sert maintenant de point fixe : seuls le bord gauche et le bas
  bougent.
- C'est la fenêtre elle-même qui change de taille, largeur et hauteur ensemble
  sur 300 ms, et l'écran sortant s'efface pendant que le cadre bouge. Elle
  sautait jusqu'ici d'une taille à l'autre en une image, et seul son contenu
  s'animait à l'intérieur : un faux-semblant, deux panneaux qui se chevauchent.
  SwiftUI mesure une vue d'après la valeur finale de son cadre, jamais d'après
  celle que l'animation dessine ; le mouvement revient donc à AppKit, qui pose
  une taille par rafraîchissement d'écran et rend chacune au contenu, qui se
  remet en page dedans. Une seule fenêtre, une seule taille à tout instant.
- Le panneau prend la taille de ce qu'il montre : 630 × 430 pour la liste des
  tâches, 320 × 370 pour le compteur, le choix de la méthode et l'écran de fin —
  aucun de ces trois n'a de liste à dérouler, et la largeur de la liste les
  laissait flotter au milieu du vide. Le passage de l'un à l'autre se fait en
  glissant, sur la courbe commune à l'application, et revenir à la liste rend
  ses 630 × 430. La poignée de redimensionnement disparaît : les deux tailles
  sont fixes.
- Le bas du panneau de la barre de menus ne sort plus du cadre. Le contenu
  prenait la place qu'il réclamait ; un avis de fin de session suffisait à
  pousser le trait et le bouton des options hors du panneau, et il n'y avait
  plus de porte vers les réglages ni vers « Quitter ». Le pied est désormais
  ancré au bas du panneau : le contenu s'arrête là où il commence, et le
  trop-plein est rogné plutôt que poussé dehors.
- Le bouton des options propose « Actualiser les tâches », détaché de
  « Réglages… » et « Quitter » par un trait. Les trois portent à nouveau leur
  icône : confié à SwiftUI, le menu les perdait selon la version de macOS — il
  est maintenant construit en AppKit, comme le choix des bases.
- Le panneau de la barre de menus a son propre fond (#f6f3f3 en thème clair,
  sa contrepartie sombre sinon) au lieu de celui, générique, du système.
- Le panneau de la barre de menus mesure 420 × 300 : de quoi lire cinq ou six
  tâches avec leur projet et leur échéance, sans recouvrir l'écran. Sa hauteur
  n'est imposée que lorsqu'il y a une liste à parcourir — sans compte relié, il
  se réduit au bouton qu'il propose.
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

- Accueil en quatre écrans, dans une fenêtre large et centrée, chaque fois
  qu'aucun compte Notion n'est relié : le récit — texte qui se dépose mot à mot, avatar incrusté dans la
  phrase, promesses en pastilles —, le template offert et sa grille de
  présentation, les deux façons de connecter Notion, puis la lecture des bases
  détectées, changeables sur place.
- Terminer l'accueil ferme la fenêtre et ouvre le menu, tâches déjà chargées.
- Se déconnecter ne rejoue pas l'accueil : on reste où l'on est, avec le bouton
  de connexion sous les yeux.
- « Le problème ? » scintille pendant le silence qui suit, et le récit reprend
  ensuite là où il s'était arrêté au lieu de se redéposer depuis le début.
- La commande de Notion est citée dans une pastille à chasse fixe (JetBrains
  Mono, embarquée), fond sombre à coins arrondis, à la taille du texte qui
  l'entoure : elle cite une commande au fil d'une phrase, elle ne l'annonce pas.
- Le nom des bases du dernier écran s'affiche bien sur fond noir, sur toutes les
  versions de macOS. Le menu de changement était bâti avec `Menu`, dont AppKit
  ne garde que le texte et l'image du libellé : sur macOS 15, la pastille
  perdait son fond et il ne restait qu'un mot blanc sur fond clair, illisible.
  La double flèche « haut et bas » accompagne le nom, à droite.
- Le dernier écran attend la fin de la détection : les bases s'affichent
  validées au lieu de passer par « à désigner » en orange.
- Le premier écran s'ouvre sur « Bienvenue dans Notitime », qui s'efface vers le
  haut pour laisser la place au récit. Celui-ci se dépose plus lentement, avec un
  silence après la question et un autre après les deux promesses, et se rejoue
  d'un bouton. Entrée déclenche le bouton principal de chaque écran.
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

- « J'ai terminé ma tâche » fait ce qu'il dit : le statut de la tâche passe à
  « terminé » dans Notion — la valeur vient du groupe « terminé » de la base, pas
  d'un libellé codé en dur — la tâche quitte la liste, et le menu revient sur
  cette liste au lieu de rouvrir le choix de la méthode. Si la base ne sait pas
  exprimer « terminé », rien n'est écrit et l'application le dit.
- La pastille du compteur se serre sur le chiffre au lieu de s'étendre à toute
  la fenêtre, et « Pause » et « Terminé » s'alignent sur sa largeur, à la
  hauteur standard des actions principales.
- Le suivi libre en cours est bâti comme l'écran de fin : le nom de la tâche en
  en-tête discret, « La session a commencé il y a… » au-dessus du compteur, le
  compteur en grand dans une pastille grise au centre, et dessous « Pause » et
  « Terminé » — cette dernière avec sa coche — alignés sur la largeur de la
  pastille.
- Ouvrir l'entrée dans Notion depuis l'écran de fin ne le perd plus : partir
  consulter ce qu'on vient d'enregistrer referme le panneau, et l'écran attend
  au retour. Refermer le panneau sans être parti le quitte, comme avant.
- « Comment veux-tu travailler ? » est écrit à la taille d'un titre : c'est la
  question de l'écran, elle ne se lit plus au même rang qu'un libellé de bouton.
- Arrêter une session ne renvoie plus directement à la liste : un écran montre
  la durée travaillée en grand, au centre, sous le nom de la tâche qui vient de
  l'occuper. « Session terminée » n'est plus qu'un en-tête discret, refermé par
  un trait. Au-dessus du chiffre, l'entrée se suit jusqu'à Notion : « On
  l'envoie dans Notion… », puis « Enregistré dans Notion » avec sa coche, qui
  ouvre la page créée d'un clic ; hors ligne, « En attente d'envoi », et
  l'entrée part d'elle-même au retour du réseau. Deux suites au centre :
  « Relancer », qui repart sur la même tâche avec la méthode précédente, et
  « J'ai terminé ma tâche », qui rend la liste. Échap ou la fermeture du panneau
  referment l'écran, sans rien changer à l'entrée — rien n'est écrit dans la
  base Tâches. Une session de moins d'une minute, qui ne produit rien, n'y passe
  pas ; un pomodoro allé à son terme garde son écran de pause.
- Le compteur du suivi libre s'arrête vraiment quand on met en pause. La pause
  en cours était notée avec une durée nulle tant qu'elle n'était pas refermée :
  le temps continuait de défiler à l'écran, et arrêter sans reprendre envoyait
  ce temps-là dans Notion comme du temps travaillé.
- En pause, une seconde ligne, en petit, dit depuis combien de temps. Elle est
  indicative : elle ne part jamais dans Notion.
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

- Le curseur est dans le champ du titre dès le clic sur « + » : il n'y a plus à
  cliquer dedans pour écrire. Le focus était demandé avant que SwiftUI n'ait posé
  le champ, et se perdait.
- Une tâche restée sans titre est abandonnée à la fermeture du menu : elle ne
  réapparaît plus à l'ouverture suivante. Rien n'a jamais été créé dans Notion à
  ce stade.
- Le sélecteur de projet est redessiné : plaque nette posée sur deux ombres, sa
  propre recherche sur fond franc, et des lignes qui se survolent, avec le
  dossier en tête et la coche du projet retenu. La liste s'ajuste au nombre de
  projets au lieu de laisser une carte à moitié vide. Le calendrier reprend la
  même plaque.
- Les champs de recherche perdent le liseré creusé d'AppKit et son halo bleu :
  une plaque douce, une loupe, rien d'autre. Le champ du menu est actif dès
  l'ouverture — son halo ne disait rien qu'on ne sache déjà.
- Le calendrier et la liste des projets s'ouvrent **par-dessus** la liste, à
  leur taille, sous le bouton qui les appelle — un clic à côté les referme.
  Dépliés dans le flux, ils poussaient les tâches vers le bas et le calendrier
  finissait sous le bord du panneau.
- Le champ de recherche n'a plus d'anneau bleu : il est actif dès l'ouverture du
  panneau, et son halo tirait l'œil là où il n'y a rien à lire.
- Pendant le chargement, « On cherche tes tâches » se tient au milieu du
  panneau, au lieu de se serrer sous la recherche.
- Les tâches ne surgissent plus d'un bloc : elles montent à leur place l'une
  après l'autre, du flou vers le net.
- Aucune tâche n'est plus teintée sans qu'on l'ait désignée. La ligne choisie
  gardait la couleur d'accent après une session, et la première tâche paraissait
  sélectionnée alors que rien ne l'était : le survol est le seul effet de fond,
  et le clavier pose le même voile discret.
- Le menu propose désormais **toutes** les tâches non terminées de la base.
  Les tâches sans responsable étaient écartées par défaut : sur une base de six
  tâches ouvertes dont quatre sans responsable, le menu n'en affichait que deux,
  sans que rien ne l'explique. Le réglage existe toujours, mais en sens inverse
  — « n'afficher que les tâches qui me sont assignées » — et il est décoché.
- Une tâche sans statut n'est plus écartée : le filtre le dit explicitement au
  lieu de s'en remettre à l'interprétation de `does_not_equal`.
- Un identifiant d'utilisateur vide ne devient plus une clause de filtre. La
  charge OAuth ne porte pas toujours d'utilisateur ; le filtre demandait alors
  les tâches assignées à personne, et n'en trouvait aucune.
- Un filtre refusé par Notion — propriété renommée, statut disparu — ne se solde
  plus par une liste vide : la base est relue sans filtre et les tâches
  terminées sont écartées localement.
- Le journal dit ce que chaque lecture a reçu, retenu et écarté, et pourquoi.
  Une liste amputée par un filtre était jusqu'ici indiscernable d'une base à
  moitié vide.
- Chaque tâche affiche son projet et son échéance. La date montrée est celle
  qui annonce une échéance — « Deadline », « Échéance », « Date limite »… — et
  jamais celles que Notion tient lui-même : création et dernière modification
  sont écartées par leur type comme par leur nom.
- Une ligne se teinte au passage du curseur. Le survol et la sélection au
  clavier restent distincts : c'est la seconde qui dit ce que fera Entrée.
- Un bouton « + » à côté de la recherche ouvre une ligne vierge en tête de
  liste — les autres descendent d'un cran — où l'on écrit le titre d'une
  nouvelle tâche. Le champ est actif dès l'ouverture : on peut écrire sans rien
  cliquer. Entrée la crée dans Notion et la laisse sélectionnée, Échap abandonne.
- « Date » déplie un calendrier au mois, précédé de deux raccourcis en colonnes,
  « Aujourd'hui » et « Demain ». La date est écrite dans la propriété d'échéance
  de la base — la même que celle affichée dans la liste, choisie par son nom et
  jamais parmi les dates du système.
- « Projet » déplie la liste des projets, les plus récemment modifiés en tête.
  La recherche porte sur tout ce que la page donne à lire — nom, textes,
  options, nombres, dates —, pas seulement sur son titre : un projet se retrouve
  par son client ou par un mot qu'il contient. Le projet choisi est écrit dans
  la relation de la tâche.
- Un statut ou un responsable ne sont toujours pas devinés à la création : les
  deviner reviendrait à décider à la place de l'utilisateur.
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

- Le mode Concentration de macOS s'active avec une session — pomodoro comme
  suivi libre — et se désactive à la fin, si l'option est cochée dans les
  réglages. macOS n'ouvre aucune porte à une application pour cela : il faut
  deux raccourcis (activer, désactiver) créés dans l'app Raccourcis, dont les
  noms se saisissent sous l'option. Leur échec n'empêche jamais une session.
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
