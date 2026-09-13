import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { signup } from '../worker/index.mjs';

let mf, db;
const origin = 'https://hivedev.sh';
const valid = { email: ' Demo+cloud@Example.com ', token: 'valid' };
const verify = async () => Response.json({ success: true, hostname: 'hivedev.sh', action: 'waitlist' });
const request = (body = valid, headers = {}) => new Request(`${origin}/api/waitlist`, {
  method: 'POST', headers: { origin, 'content-type': 'application/json', ...headers }, body: JSON.stringify(body)
});
const env = () => ({ DB: db, TURNSTILE_SECRET: 'test-secret', SITE_ORIGIN: origin, SIGNUP_COPY_REVISION: '2026-09-13' });
const count = async () => (await db.prepare('SELECT COUNT(*) AS count FROM waitlist').first()).count;

before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script: 'export default {fetch(){return new Response("test")}}',
    compatibilityDate: '2026-09-11', d1Databases: ['DB'] }));
  db = await mf.getD1Database('DB');
  await db.prepare(await readFile(new URL('../migrations/0001_waitlist.sql', import.meta.url), 'utf8')).run();
});
after(async () => mf?.dispose());
beforeEach(async () => { await db.prepare('DELETE FROM waitlist').run(); });

test('stores signup in D1 and atomically deduplicates concurrent normalized emails', async () => {
  const responses = await Promise.all([signup(request(), env(), verify), signup(request({ ...valid, email: 'demo+cloud@example.com' }), env(), verify)]);
  assert.deepEqual(await Promise.all(responses.map(r => r.json())), [{ ok: true }, { ok: true }]);
  assert.equal(await count(), 1);
  const row = await db.prepare('SELECT * FROM waitlist').first();
  assert.equal(row.email_key, 'demo+cloud@example.com');
  assert.equal(row.source, 'hivedev-demo');
  assert.ok(row.created_at);
  assert.equal(responses[0].headers.get('cache-control'), 'no-store');
});

test('rejects malformed, oversized and invalid emails without contacting verifier', async () => {
  let calls = 0;
  const unused = () => { calls++; throw new Error('unexpected verification'); };
  for (const body of [{ email: 'bad', token: 'x' }, { email: null, token: 'x' }, { email: 'a@b.com', token: '' }, { email: 'a'.repeat(5000), token: 'x' }]) {
    assert.ok((await signup(request(body), env(), unused)).status >= 400);
  }
  const malformed = new Request(`${origin}/api/waitlist`, { method: 'POST', headers: { origin, 'content-type': 'application/json' }, body: '{' });
  assert.equal((await signup(malformed, env(), unused)).status, 400);
  assert.equal(calls, 0);
  assert.equal(await count(), 0);
});

test('rejects origin mismatch, wrong method and wrong content type', async () => {
  assert.equal((await signup(request(valid, { origin: 'https://other.example' }), env(), verify)).status, 403);
  assert.equal((await signup(new Request(`${origin}/api/waitlist`), env(), verify)).status, 405);
  assert.equal((await signup(request(valid, { 'content-type': 'text/plain' }), env(), verify)).status, 415);
  assert.equal(await count(), 0);
});

test('fails closed for failed, replayed, wrong hostname/action or unavailable Turnstile', async () => {
  for (const response of [{ success: false, 'error-codes': ['timeout-or-duplicate'] }, { success: true, hostname: 'other.example', action: 'waitlist' }, { success: true, hostname: 'hivedev.sh', action: 'login' }]) {
    assert.equal((await signup(request(), env(), async () => Response.json(response))).status, 400);
  }
  assert.equal((await signup(request(), env(), async () => { throw new Error('offline'); })).status, 503);
  assert.equal((await signup(request(), env(), async () => new Response('broken', { status: 500 }))).status, 503);
  assert.equal(await count(), 0);
});

test('missing configuration and database failure cannot return success or leak errors', async () => {
  assert.equal((await signup(request(), { ...env(), TURNSTILE_SECRET: '' }, verify)).status, 503);
  assert.equal((await signup(request(), { ...env(), DB: null }, verify)).status, 503);
  const broken = { prepare() { throw new Error('secret database detail'); } };
  const response = await signup(request(), { ...env(), DB: broken }, verify);
  assert.equal(response.status, 503);
  assert.equal((await response.text()).includes('secret'), false);
});

test('retry after a lost response confirms existing row using a fresh challenge', async () => {
  await signup(request(), env(), verify); // client never received this response
  const response = await signup(request({ ...valid, token: 'fresh-token' }), env(), verify);
  assert.equal(response.status, 200);
  assert.equal(await count(), 1);
});
