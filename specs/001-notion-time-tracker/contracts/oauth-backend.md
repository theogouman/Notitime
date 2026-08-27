# Contract: Backend OAuth Notion

**Feature**: 001-notion-time-tracker | **Date**: 2026-08-27 | **Hébergement**: Vercel (fonctions serverless, dossier `backend/` du dépôt)

## Rôle et limites

Le backend existe pour une seule raison : le client secret OAuth ne peut pas être embarqué dans l'application macOS. Il ne stocke rien, ne journalise aucun token ni code, n'a pas de base de données. Trois routes, toutes sans état.

## Flow complet

```
App                          Navigateur (ASWebAuthenticationSession)        Backend Vercel                 Notion
 |                                                                                                            |
 | 1. génère verifier (32 octets aléatoires, base64url)                                                       |
 |    state = base64url(sha256(verifier))                                                                     |
 |                                                                                                            |
 | 2. ouvre https://api.notion.com/v1/oauth/authorize                                                         |
 |      ?client_id=...&response_type=code&owner=user                                                          |
 |      &redirect_uri=https://auth.notitime.fr/api/notion/callback&state=<state>                                        |
 |                                     |---- l'utilisateur autorise / duplique le template ------------------>|
 |                                     |<--- 302 https://auth.notitime.fr/api/notion/callback?code=..&state=.. ---------|
 |                                     |----> GET /api/notion/callback ---------->|                           |
 |                                     |<---- 302 notitime://auth?code=..&state=..|  (aucun échange ici)      |
 | 3. reçoit notitime://auth, vérifie state == sha256(verifier)                                               |
 |                                                                                                            |
 | 4. POST https://auth.notitime.fr/api/notion/token {code, state, verifier} --------------->|                          |
 |                                                                                 | vérifie sha256(verifier)==state
 |                                                                                 |-- POST /v1/oauth/token -->|
 |                                                                                 |   Basic client_id:secret  |
 |                                                                                 |<-- tokens + metadata -----|
 | <------------------------ 200 JSON (réponse Notion relayée telle quelle) -------|                          |
 |                                                                                                            |
 | 5. stocke access_token + refresh_token dans le Keychain ; workspace_id, bot_id, owner,                     |
 |    duplicated_template_id, workspace_name/icon en local.                                                   |
```

Pourquoi ne pas échanger le code directement dans `/callback` et rediriger avec les tokens dans l'URL : n'importe quelle application du Mac peut enregistrer le scheme `notitime://`. Avec ce flow, l'URL de callback ne transporte que le `code` (usage unique, courte durée) et le `state` ; seule l'application qui détient le `verifier` peut obtenir les tokens. Notion ne supporte pas PKCE nativement, ce mécanisme le reproduit côté backend sans stockage.

## Routes

### `GET /api/notion/callback`

Entrée (query) : `code`, `state`, ou `error` (+ `state`) si l'utilisateur a annulé.

Comportement :
- Si `error` présent : `302 notitime://auth?error=<error>&state=<state>`.
- Si `code` et `state` présents et bien formés (`state` : base64url de 32 octets) : `302 notitime://auth?code=<code>&state=<state>`.
- Sinon : `400` avec page texte minimale.
- Ne fait aucun appel à Notion. Ne journalise ni `code` ni `state`.
- Réponse avec `Cache-Control: no-store`.

### `POST /api/notion/token`

Entrée (JSON) : `{ "code": string, "state": string, "verifier": string }`.

Comportement :
1. Vérifie que `base64url(sha256(verifier)) == state`, sinon `400 {"error":"invalid_verifier"}`.
2. Appelle `POST https://api.notion.com/v1/oauth/token` avec `Authorization: Basic base64(CLIENT_ID:CLIENT_SECRET)` et le corps `{"grant_type":"authorization_code","code":code,"redirect_uri":REDIRECT_URI}`.
3. Relaye la réponse Notion telle quelle (statut et corps), y compris en cas d'erreur OAuth (`invalid_grant`, etc.). Le corps en succès contient `access_token`, `refresh_token`, `bot_id`, `workspace_id`, `workspace_name`, `workspace_icon`, `owner`, `duplicated_template_id`.
4. `Cache-Control: no-store`. Aucun log du corps.

### `POST /api/notion/refresh`

Entrée (JSON) : `{ "refresh_token": string }`.

Comportement : appelle `POST https://api.notion.com/v1/oauth/token` avec le même en-tête Basic et le corps `{"grant_type":"refresh_token","refresh_token":...}`, relaye la réponse telle quelle. Notion renvoie un nouveau couple `access_token` / `refresh_token` ; l'application doit remplacer les deux.

### Commun

- Méthodes non prévues : `405`.
- Corps JSON invalide : `400 {"error":"invalid_request"}`.
- Erreur réseau vers Notion : `502 {"error":"upstream_unavailable"}`.
- Pas de CORS nécessaire (client natif). Refuser explicitement les requêtes avec en-tête `Origin` d'un navigateur est acceptable mais non requis.
- Aucun `console.log` contenant code, state, verifier, tokens.

## Variables d'environnement (Vercel, chiffrées)

| Nom | Valeur |
|---|---|
| `NOTION_CLIENT_ID` | depuis le portail développeur Notion |
| `NOTION_CLIENT_SECRET` | idem, jamais commité |
| `NOTION_REDIRECT_URI` | `https://auth.notitime.fr/api/notion/callback`, identique caractère pour caractère à celle déclarée chez Notion |
| `APP_CALLBACK_SCHEME` | `notitime` |

En local : `.env.local` (ignoré par git), `vercel env pull`.

## Côté application (rappel du contrat)

- `ASWebAuthenticationSession` avec `callbackURLScheme: "notitime"`, `prefersEphemeralWebBrowserSession = false` (l'utilisateur doit être connecté à Notion dans son navigateur).
- `Info.plist` : `CFBundleURLTypes` déclarant le scheme `notitime`.
- Le `verifier` ne quitte jamais la mémoire du processus avant l'étape 4 ; il est jeté après.
- Rafraîchissement : sur réponse `401` de l'API Notion ou de façon proactive selon l'expiration si Notion la communique. Un échec de refresh avec `invalid_grant` déconnecte l'utilisateur (tokens supprimés du Keychain) sans vider la file d'envoi.

## Configuration côté Notion (portail développeur)

- Type : connexion publique. Périmètre d'installation : Any workspace.
- Redirect URI : exactement `NOTION_REDIRECT_URI`. Une seule URI déclarée en v1 pour que le paramètre `redirect_uri` reste optionnel dans l'échange ; il est envoyé quand même par sécurité.
- Capacités : lire le contenu, insérer du contenu, mettre à jour le contenu (création des propriétés manquantes), insérer des commentaires (motif d'écourtement, FR-026a), lire les informations utilisateur sans email.
- Template : URL de la page publique Notitime (ajoutée dès que le template est prêt ; le flow fonctionne sans en attendant).

## Cas de test (backend)

1. `POST /token` avec un `verifier` dont le hash ne correspond pas au `state` → `400 invalid_verifier`, aucun appel Notion.
2. `GET /callback?error=access_denied&state=x` → `302` vers `notitime://auth?error=access_denied&state=x`.
3. `GET /callback` sans paramètres → `400`.
4. `POST /token` valide avec Notion simulé → relais du corps et du statut.
5. `POST /refresh` avec `invalid_grant` simulé → relais du `400` Notion.
