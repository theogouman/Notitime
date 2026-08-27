# Sources graphiques

Les SVG sont la source de vérité ; les PNG du catalogue en sont dérivés.

| Fichier | Sert à | Rendu |
| --- | --- | --- |
| `notitime-icon.svg` | icône de l'app (Dock, Finder, À propos) | `App/Resources/Assets.xcassets/AppIcon.appiconset` |
| `notitime-template.svg` | icône de la barre de menus | `App/Resources/Assets.xcassets/MenuBarIcon.imageset` |
| `notion.svg` | logo Notion fourni, tel quel (référence) | — |
| `notion-mark.svg` | logo Notion du bouton de connexion | `App/Resources/Assets.xcassets/NotionLogo.imageset` |

## Régénérer

```sh
swift scripts/render-icons.swift
```

Aucun outil externe n'est requis : `NSImage` lit le SVG nativement. Les PNG sont
commités — le projet doit rester constructible sans lancer ce script.

## Contraintes à respecter en cas de remplacement

**Icône de l'app.** Le SVG dessine son fond arrondi bord à bord, convention iOS.
Le rendu l'inscrit dans la grille macOS — 824 sur un canevas de 1024 — sans quoi
l'icône paraîtrait plus grosse que ses voisines dans le Dock. Le facteur est
`macOSGridInset` dans le script.

**Logo Notion.** `notion-mark.svg` est le seul tracé noir de `notion.svg`, sans
la page blanche qu'il recouvre : rendu en gabarit, un aplat blanc deviendrait
opaque et masquerait le « N ». Le gabarit prend la couleur du libellé du bouton,
ce qui le garde lisible sur fond teinté comme dans les deux thèmes — un logo noir
figé disparaîtrait sur l'un des deux.

**Barre de menus.** Le gabarit doit être **monochrome et à trous** : le système
n'en garde que l'opacité pour le teinter selon le thème clair ou sombre et l'état
sélectionné du menu. Les yeux sont des découpes (`fill-rule="evenodd"`), pas des
formes blanches — une forme blanche disparaîtrait sur fond clair. Aucune couleur,
aucun dégradé : ils seraient ignorés. Le catalogue le déclare par
`"template-rendering-intent": "template"`.
