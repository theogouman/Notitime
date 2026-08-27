import { noStore, methodNotAllowed, isWellFormedState } from './_shared.js';

const scheme = () => process.env.APP_CALLBACK_SCHEME || 'notitime';

/**
 * GET /api/notion/callback
 *
 * Ne fait AUCUN appel à Notion : elle se contente de rediriger vers l'app.
 * L'URL de callback ne transporte donc que le `code`, à usage unique et de
 * courte durée, et le `state` — jamais de token. C'est ce qui rend inoffensive
 * l'usurpation du scheme `notitime://` par une autre application.
 *
 * Ne journalise ni `code` ni `state`.
 */
export default function handler(request, response) {
  if (request.method !== 'GET') return methodNotAllowed(response, 'GET');

  const { code, state, error } = request.query ?? {};

  if (typeof error === 'string' && error.length > 0) {
    const target = `${scheme()}://auth?error=${encodeURIComponent(error)}`
      + (typeof state === 'string' ? `&state=${encodeURIComponent(state)}` : '');
    noStore(response);
    return response.redirect(302, target);
  }

  if (typeof code === 'string' && code.length > 0 && isWellFormedState(state)) {
    const target = `${scheme()}://auth?code=${encodeURIComponent(code)}`
      + `&state=${encodeURIComponent(state)}`;
    noStore(response);
    return response.redirect(302, target);
  }

  noStore(response).setHeader('Content-Type', 'text/plain; charset=utf-8');
  return response.status(400).send(
    "Requête d'autorisation incomplète. Relancez la connexion depuis Notitime."
  );
}
