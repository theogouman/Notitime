import {
  methodNotAllowed, invalidRequest, verifierMatchesState, relayToNotion, readJsonBody
} from './_shared.js';

/**
 * POST /api/notion/token — { code, state, verifier }
 *
 * Vérifie que `base64url(sha256(verifier)) === state` avant tout appel à Notion,
 * puis échange le code en Basic auth et relaye la réponse telle quelle.
 */
export default async function handler(request, response, fetchImpl = fetch) {
  if (request.method !== 'POST') return methodNotAllowed(response, 'POST');

  const body = await readJsonBody(request);
  if (!body) return invalidRequest(response);

  const { code, state, verifier } = body;
  if (typeof code !== 'string' || !code) return invalidRequest(response);

  // Échec avant tout appel réseau : un verifier qui ne correspond pas au state
  // signifie que l'appelant n'est pas l'application qui a lancé le flux.
  if (!verifierMatchesState(verifier, state)) {
    return response.status(400).json({ error: 'invalid_verifier' });
  }

  return relayToNotion(response, {
    grant_type: 'authorization_code',
    code,
    redirect_uri: process.env.NOTION_REDIRECT_URI
  }, fetchImpl);
}
