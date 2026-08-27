# Backend OAuth Notitime

Trois fonctions sans état, dont l'unique rôle est de porter le client secret OAuth
Notion. Elles ne stockent rien, ne journalisent ni code, ni state, ni verifier, ni
token, et n'ont pas de base de données. Le contrat fait foi :
[`specs/001-notion-time-tracker/contracts/oauth-backend.md`](../specs/001-notion-time-tracker/contracts/oauth-backend.md).

## Portabilité — condition de l'écart accepté

Le plan Hobby de Vercel exclut l'usage commercial ; l'écart est accepté pour la v1
interne et non commerciale, **à condition** que ces fonctions restent écrites contre
l'API HTTP standard, sans dépendance à une primitive propriétaire de la plateforme
(stockage, file, cache, edge config). Le passage en plan Pro ou la migration vers un
autre hébergeur est un prérequis de la v2 « licence par workspace ».

Concrètement : pas de `@vercel/*` en dépendance de production, pas d'import de KV,
Blob ou Postgres. Les handlers reçoivent une requête et rendent une réponse.

## Variables d'environnement

| Nom | Valeur |
|---|---|
| `NOTION_CLIENT_ID` | portail développeur Notion |
| `NOTION_CLIENT_SECRET` | idem, jamais commité |
| `NOTION_REDIRECT_URI` | `https://auth.notitime.fr/api/notion/callback` |
| `APP_CALLBACK_SCHEME` | `notitime` |

En local : `vercel env pull` produit `.env.local`, ignoré par git.

## Commandes

```bash
npm test              # suite locale, Notion simulé, aucun appel réseau réel
vercel deploy --prod
```

Les routes sont implémentées en Phase 3 (US1) : T028 à T030 de `tasks.md`.
