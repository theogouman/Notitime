import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

import callback from '../api/notion/callback.js';
import token from '../api/notion/token.js';
import refresh from '../api/notion/refresh.js';
import { base64url } from '../api/notion/_shared.js';
import { makeRequest, makeResponse, fakeFetch, withEnv } from './helpers.js';

const ENV = {
  NOTION_CLIENT_ID: 'client-id',
  NOTION_CLIENT_SECRET: 'client-secret',
  NOTION_REDIRECT_URI: 'https://auth.notitime.fr/api/notion/callback',
  APP_CALLBACK_SCHEME: 'notitime'
};

const verifier = 'un-verifier-de-32-octets-au-moins-aleatoire';
const state = base64url(createHash('sha256').update(verifier).digest());

// Cas 1 du contrat — un verifier qui ne correspond pas au state est rejeté
// AVANT tout appel à Notion.
test('POST /token : verifier ne correspondant pas au state → 400, aucun appel Notion', async () => {
  const fetchImpl = fakeFetch();
  const res = makeResponse();

  await withEnv(ENV, () => token(
    makeRequest({ method: 'POST', body: { code: 'c', state, verifier: 'mauvais' } }),
    res, fetchImpl
  ));

  assert.equal(res.statusCode, 400);
  assert.deepEqual(res.body, { error: 'invalid_verifier' });
  assert.equal(fetchImpl.calls.length, 0, 'Notion ne doit pas être appelé');
});

// Cas 2 — l'utilisateur annule dans Notion.
test('GET /callback : erreur relayée vers le scheme de l’app', async () => {
  const res = makeResponse();
  await withEnv(ENV, () => callback(
    makeRequest({ query: { error: 'access_denied', state: 'x' } }), res
  ));

  assert.equal(res.statusCode, 302);
  assert.equal(res.redirectedTo, 'notitime://auth?error=access_denied&state=x');
  assert.equal(res.headers['cache-control'], 'no-store');
});

// Cas 3 — appel sans paramètre.
test('GET /callback sans paramètre → 400 en texte', async () => {
  const res = makeResponse();
  await withEnv(ENV, () => callback(makeRequest({ query: {} }), res));

  assert.equal(res.statusCode, 400);
  assert.match(res.headers['content-type'], /text\/plain/);
  assert.equal(res.redirectedTo, null);
});

test('GET /callback : state mal formé → 400, pas de redirection', async () => {
  const res = makeResponse();
  await withEnv(ENV, () => callback(
    makeRequest({ query: { code: 'abc', state: 'trop-court' } }), res
  ));

  // Un state hors format ne vient pas du flux qu'on a lancé : ne pas le
  // propager au scheme de l'app.
  assert.equal(res.statusCode, 400);
  assert.equal(res.redirectedTo, null);
});

test('GET /callback nominal → 302 vers notitime://auth avec code et state', async () => {
  const res = makeResponse();
  await withEnv(ENV, () => callback(
    makeRequest({ query: { code: 'le-code', state } }), res
  ));

  assert.equal(res.statusCode, 302);
  assert.equal(res.redirectedTo, `notitime://auth?code=le-code&state=${encodeURIComponent(state)}`);
});

// Cas 4 — échange nominal : relais du corps et du statut.
test('POST /token valide → relais tel quel du corps et du statut Notion', async () => {
  const payload = JSON.stringify({
    access_token: 'ntn_access', refresh_token: 'ntn_refresh',
    bot_id: 'bot', workspace_id: 'ws', workspace_name: 'Équipe',
    owner: { user: { id: 'user-1' } }, duplicated_template_id: 'tpl-1'
  });
  const fetchImpl = fakeFetch({ status: 200, body: payload });
  const res = makeResponse();

  await withEnv(ENV, () => token(
    makeRequest({ method: 'POST', body: { code: 'le-code', state, verifier } }),
    res, fetchImpl
  ));

  assert.equal(res.statusCode, 200);
  assert.equal(res.body, payload);
  assert.equal(res.headers['cache-control'], 'no-store');

  const [call] = fetchImpl.calls;
  assert.equal(call.url, 'https://api.notion.com/v1/oauth/token');
  assert.match(call.init.headers.Authorization, /^Basic /);
  const sent = JSON.parse(call.init.body);
  assert.equal(sent.grant_type, 'authorization_code');
  assert.equal(sent.redirect_uri, ENV.NOTION_REDIRECT_URI);
});

// Cas 5 — un invalid_grant est relayé, pas absorbé : c'est l'app qui décide.
test('POST /refresh : invalid_grant relayé tel quel', async () => {
  const payload = JSON.stringify({ error: 'invalid_grant' });
  const fetchImpl = fakeFetch({ status: 400, body: payload });
  const res = makeResponse();

  await withEnv(ENV, () => refresh(
    makeRequest({ method: 'POST', body: { refresh_token: 'rt' } }), res, fetchImpl
  ));

  assert.equal(res.statusCode, 400);
  assert.equal(res.body, payload);
});

test('POST /refresh sans refresh_token → 400 invalid_request', async () => {
  const res = makeResponse();
  await withEnv(ENV, () => refresh(makeRequest({ method: 'POST', body: {} }), res, fakeFetch()));

  assert.equal(res.statusCode, 400);
  assert.deepEqual(res.body, { error: 'invalid_request' });
});

test('méthodes non prévues → 405', async () => {
  for (const [handler, method] of [[callback, 'POST'], [token, 'GET'], [refresh, 'GET']]) {
    const res = makeResponse();
    await withEnv(ENV, () => handler(makeRequest({ method }), res, fakeFetch()));
    assert.equal(res.statusCode, 405);
  }
});

test('panne réseau vers Notion → 502 upstream_unavailable', async () => {
  const res = makeResponse();
  await withEnv(ENV, () => token(
    makeRequest({ method: 'POST', body: { code: 'c', state, verifier } }),
    res, fakeFetch({ throws: true })
  ));

  assert.equal(res.statusCode, 502);
  assert.deepEqual(res.body, { error: 'upstream_unavailable' });
});
