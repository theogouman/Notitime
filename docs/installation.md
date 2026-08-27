# Installer Notitime

## Ce que macOS va vous demander

Le bundle est signé en ad-hoc mais **pas par un identifiant de développeur
Apple**. Trois conséquences, toutes normales :

1. **À la première ouverture**, macOS refuse de lancer l'application. Ouvrez
   Réglages Système › Confidentialité et sécurité, puis « Ouvrir quand même ».
2. **Après chaque mise à jour**, le trousseau redemande l'autorisation d'accéder
   aux jetons Notion : l'identité de code change à chaque version. Vos jetons
   sont intacts ; refuser n'entraîne aucune déconnexion.
3. **Les notifications** peuvent être refusées par le système. Le son de fin de
   session, lui, est toujours joué.

## Installation

1. Copiez `Notitime.app` dans `/Applications`.
2. Lancez-la. Une icône de minuteur apparaît dans la barre de menus ; il n'y a
   ni fenêtre ni icône dans le Dock.
3. Ouvrez le menu, puis « Configurer Notitime… ».
4. Connectez votre workspace Notion. Choisissez de dupliquer le template si
   vous n'avez pas encore les trois bases.

## Vérifier que tout fonctionne

Démarrez un pomodoro court sur une tâche, laissez-le aller à son terme, puis
ouvrez la base Time Tracker dans Notion : l'entrée doit s'y trouver, reliée à la
tâche, avec ses dates, sa durée, sa méthode et son responsable.

En cas de doute, le journal se trouve dans
`~/Library/Application Support/Notitime/Logs/notitime.log` et s'exporte depuis
les réglages. Il ne contient ni jeton, ni code d'autorisation, ni titre de tâche.
