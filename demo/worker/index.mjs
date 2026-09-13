const MAX_BYTES = 4096;
const reply = (status, error) => Response.json(error ? { ok: false, error } : { ok: true }, {
  status, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
});

async function boundedJSON(request) {
  if (Number(request.headers.get('content-length')) > MAX_BYTES) throw new RangeError();
  const reader = request.body?.getReader();
  if (!reader) throw new SyntaxError();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BYTES) throw new RangeError();
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}

// The optional fetch argument lets tests exercise failure paths without network access.
// Deployment always uses the platform fetch implementation.
export async function signup(request, env, verifyFetch = fetch) {
  if (request.method !== 'POST') {
    const response = reply(405, 'Use the signup form to join the waitlist.');
    response.headers.set('Allow', 'POST');
    return response;
  }
  const url = new URL(request.url);
  if (!env.DB || !env.TURNSTILE_SECRET || !env.SIGNUP_COPY_REVISION || !env.SITE_ORIGIN) {
    return reply(503, 'The waitlist is temporarily unavailable. Please try again later.');
  }
  // A preview must never accept production-origin registrations.
  if (env.SITE_ORIGIN !== url.origin || request.headers.get('origin') !== url.origin) {
    return reply(403, 'Please submit the form from this website.');
  }
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') {
    return reply(415, 'Please use the email signup form.');
  }
  let body;
  try { body = await boundedJSON(request); }
  catch (error) { return reply(error instanceof RangeError ? 413 : 400, 'Please enter a valid email address.'); }
  const email = typeof body?.email === 'string' ? body.email.trim() : '';
  const token = body?.token;
  if (email.length > 254 || !/^[^\s@\x00-\x1f\x7f]+@[^\s@\x00-\x1f\x7f]+\.[^\s@\x00-\x1f\x7f]+$/.test(email)) {
    return reply(400, 'Please enter a valid email address.');
  }
  if (typeof token !== 'string' || !token || token.length > 2048) {
    return reply(400, 'Please complete the verification and try again.');
  }
  let verification;
  try {
    const result = await verifyFetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST', body: new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token }),
      signal: AbortSignal.timeout(8000)
    });
    if (!result.ok) throw new Error('verification unavailable');
    verification = await result.json();
  } catch {
    return reply(503, 'Verification is temporarily unavailable. Please try again.');
  }
  if (verification?.success !== true || verification.hostname !== url.hostname || verification.action !== 'waitlist') {
    return reply(400, 'Verification expired or failed. Please try again.');
  }
  try {
    const result = await env.DB.prepare(
      'INSERT INTO waitlist (email, email_key, source, signup_copy_revision) VALUES (?, ?, ?, ?) ON CONFLICT(email_key) DO NOTHING'
    ).bind(email, email.toLowerCase(), 'hivedev-demo', env.SIGNUP_COPY_REVISION).run();
    if (!result.success) throw new Error('write failed');
  } catch {
    return reply(503, 'Your signup could not be confirmed. Please try again.');
  }
  return reply(200);
}

export default {
  async fetch(request, env) {
    if (new URL(request.url).pathname === '/api/waitlist') return signup(request, env);
    return new Response('Not found', { status: 404 });
  }
};
