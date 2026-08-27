// Helpers partagés des trois routes. Aucune dépendance : la portabilité du
// backend est une condition de l'écart accepté sur le plan Hobby de Vercel.
import { createHash, timingSafeEqual } from 'node:crypto';

export const NOTION_TOKEN_URL = 'https://api.notion.com/v1/oauth/token';

export function noStore(response) {
  response.setHeader('Cache-Control', 'no-store');
  return response;
}

export function methodNotAllowed(response, allowed) {
  noStore(response).setHeader('Allow', allowed);
  return response.status(405).json({ error: 'method_not_allowed' });
}

export function invalidRequest(response) {
  return noStore(response).status(400).json({ error: 'invalid_request' });
}

export function upstreamUnavailable(response) {
  return noStore(response).status(502).json({ error: 'upstream_unavailable' });
}

export function base64url(buffer) {
  return Buffer.from(buffer).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * Reproduit PKCE côté backend : seule l'application qui détient le `verifier`
 * peut échanger le `code`. Sans cela, n'importe quelle app du Mac ayant
 * enregistré le scheme `notitime://` pourrait capter le code et obtenir les
 * tokens. Comparaison à temps constant : la valeur est un secret.
 */
export function verifierMatchesState(verifier, state) {
  if (typeof verifier !== 'string' || typeof state !== 'string') return false;
  const expected = Buffer.from(base64url(createHash('sha256').update(verifier).digest()));
  const provided = Buffer.from(state);
  if (expected.length !== provided.length) return false;
  return timingSafeEqual(expected, provided);
}

/** `state` attendu : base64url de 32 octets, soit 43 caractères sans padding. */
export function isWellFormedState(state) {
  return typeof state === 'string' && /^[A-Za-z0-9_-]{43}$/.test(state);
}

export function basicAuthHeader() {
  const id = process.env.NOTION_CLIENT_ID;
  const secret = process.env.NOTION_CLIENT_SECRET;
  if (!id || !secret) throw new Error('missing_credentials');
  return `Basic ${Buffer.from(`${id}:${secret}`).toString('base64')}`;
}

/**
 * Relaye la réponse Notion telle quelle — statut et corps — y compris en erreur
 * OAuth. L'application décide : un `invalid_grant` sur un refresh la déconnecte.
 * Aucun log du corps : il contient les tokens.
 */
export async function relayToNotion(response, body, fetchImpl = fetch) {
  let upstream;
  try {
    upstream = await fetchImpl(NOTION_TOKEN_URL, {
      method: 'POST',
      headers: {
        Authorization: basicAuthHeader(),
        'Content-Type': 'application/json',
        Accept: 'application/json'
      },
      body: JSON.stringify(body)
    });
  } catch {
    return upstreamUnavailable(response);
  }

  const text = await upstream.text();
  noStore(response).setHeader('Content-Type', 'application/json');
  return response.status(upstream.status).send(text);
}

export async function readJsonBody(request) {
  if (request.body && typeof request.body === 'object') return request.body;
  if (typeof request.body === 'string') {
    try { return JSON.parse(request.body); } catch { return null; }
  }
  return null;
}
