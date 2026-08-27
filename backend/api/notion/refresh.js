import { methodNotAllowed, invalidRequest, relayToNotion, readJsonBody } from './_shared.js';

/**
 * POST /api/notion/refresh — { refresh_token }
 *
 * Notion renvoie un nouveau couple access/refresh : l'application doit
 * remplacer les deux. Un `invalid_grant` relayé tel quel déconnecte
 * l'utilisateur côté app, sans vider la file d'envoi.
 */
export default async function handler(request, response, fetchImpl = fetch) {
  if (request.method !== 'POST') return methodNotAllowed(response, 'POST');

  const body = await readJsonBody(request);
  if (!body || typeof body.refresh_token !== 'string' || !body.refresh_token) {
    return invalidRequest(response);
  }

  return relayToNotion(response, {
    grant_type: 'refresh_token',
    refresh_token: body.refresh_token
  }, fetchImpl);
}
