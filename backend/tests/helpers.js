// Doublure minimale de la réponse Vercel : de quoi observer statut, en-têtes et
// corps sans lancer de serveur.
export function makeResponse() {
  const res = {
    statusCode: null,
    headers: {},
    body: null,
    redirectedTo: null,
    setHeader(key, value) { this.headers[key.toLowerCase()] = value; return this; },
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; return this; },
    send(payload) { this.body = payload; return this; },
    redirect(code, target) { this.statusCode = code; this.redirectedTo = target; return this; }
  };
  return res;
}

export function makeRequest({ method = 'GET', query = {}, body = null } = {}) {
  return { method, query, body };
}

/** `fetch` simulé : aucun appel réseau réel dans la suite. */
export function fakeFetch({ status = 200, body = '{}', throws = false } = {}) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init });
    if (throws) throw new Error('network down');
    return { status, text: async () => body };
  };
  impl.calls = calls;
  return impl;
}

// `await run()` et non `return run()` : les handlers sont asynchrones, et rendre
// la promesse sans l'attendre restaurerait l'environnement avant qu'ils ne
// lisent process.env — les identifiants seraient déjà effacés.
export async function withEnv(vars, run) {
  const previous = {};
  for (const [key, value] of Object.entries(vars)) {
    previous[key] = process.env[key];
    process.env[key] = value;
  }
  try {
    return await run();
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  }
}
