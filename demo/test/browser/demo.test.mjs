import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, stat } from 'node:fs/promises';
import { resolve, extname, sep, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { signup } from '../../worker/index.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const leadTask = '/tasks/screenote/add-image-attachments-to-screenote-260816-6a00';
let server, base, browser, mf, db, loseResponse = false, failWrite = false, delayWrite = false;
let submittedTokens = [];
const challengeJS = `window.turnstile={render(container, options){window.challengeOptions=options;const id=String(++window.challengeCount);setTimeout(()=>options.callback('token-'+id),0);return id},remove(){}};window.challengeCount=0;`;
const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.patch': 'text/plain' };

const distFile = async pathname => {
  const base = resolve(`${root}dist`);
  const candidate = resolve(join(base, pathname));
  if (candidate !== base && !candidate.startsWith(`${base}${sep}`)) return null;
  try {
    const info = await stat(candidate);
    if (info.isDirectory()) return join(candidate, 'index.html');
    return candidate;
  } catch {
    return null;
  }
};

before(async () => {
  mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script: 'export default {fetch(){return new Response("test")}}', compatibilityDate: '2026-09-11', d1Databases: ['DB'] }));
  db = await mf.getD1Database('DB');
  await db.prepare(await readFile(`${root}migrations/0001_waitlist.sql`, 'utf8')).run();
  server = createServer(async (req, res) => {
    try {
      if (req.url === '/api/waitlist') {
        const chunks = []; for await (const chunk of req) chunks.push(chunk);
        const request = new Request(`${base}/api/waitlist`, { method: req.method, headers: req.headers, body: Buffer.concat(chunks) });
        const env = { DB: failWrite ? null : db, TURNSTILE_SECRET: 'fixture', SITE_ORIGIN: base, SIGNUP_COPY_REVISION: 'test' };
        if (delayWrite) await new Promise(resolve => setTimeout(resolve, 400));
        const response = await signup(request, env, async (_url, options) => {
          submittedTokens.push(options.body.get('response'));
          return Response.json({ success: true, hostname: '127.0.0.1', action: 'waitlist' });
        });
        if (loseResponse) { loseResponse = false; res.writeHead(200, { 'content-type': 'application/json' }); res.end('{'); return; }
        res.writeHead(response.status, Object.fromEntries(response.headers)); res.end(await response.text()); return;
      }
      const pathname = decodeURIComponent(new URL(req.url, base).pathname);
      const path = await distFile(pathname) || await distFile('/404.html');
      let data = await readFile(path);
      if (path.endsWith('/index.html')) {
        data = data.toString().replace(/<script id="demo-config" type="application\/json">.*?<\/script>/,
          '<script id="demo-config" type="application/json">{"turnstileSiteKey":"fixture","waitlistEnabled":true}</script>');
      }
      res.writeHead(path.endsWith('404.html') ? 404 : 200, { 'content-type': types[extname(path)] || 'application/octet-stream' });
      res.end(data);
    } catch { res.writeHead(404); res.end('Not found'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true });
  await mkdir(`${root}test-results`, { recursive: true });
});
after(async () => { await browser?.close(); await new Promise(resolve => server?.close(resolve)); await mf?.dispose(); });

async function context(options = {}) {
  const ctx = await browser.newContext(options);
  await ctx.route('https://challenges.cloudflare.com/**', route => route.fulfill({ contentType: 'text/javascript', body: challengeJS }));
  return ctx;
}

async function open(page, path = '/') {
  await page.goto(`${base}${path}`, { waitUntil: 'networkidle' });
}

test('desktop: frozen board, lead task evidence, archive navigation, direct filters, no live connections', async () => {
  const ctx = await context({ viewport: { width: 1440, height: 1000 } });
  const page = await ctx.newPage();
  const external = [], sockets = [], errors = [];
  page.on('request', request => { if (!request.url().startsWith(base)) external.push(request.url()); });
  page.on('websocket', socket => sockets.push(socket.url()));
  page.on('pageerror', error => errors.push(error.message));

  await open(page);
  assert.equal(await page.locator('article.kanban-card').count(), 2);
  assert.equal(await page.locator('form:not(#waitlist-form), turbo-frame, turbo-stream, [data-controller]').count(), 0);
  assert.equal(await page.getByText('Explore 10 completed tasks across 5 projects').count(), 1);
  await page.screenshot({ path: `${root}test-results/desktop-board.png`, fullPage: true });

  await page.getByRole('link', { name: 'Start with image attachments' }).click();
  await page.waitForSelector('#workspace-primary-result');
  assert.match(await page.locator('#workspace-primary-result').innerText(), /image attachment/i);
  assert.ok(await page.getByRole('link', { name: 'PR #67' }).count() >= 1);
  await page.screenshot({ path: `${root}test-results/desktop-task.png`, fullPage: true });

  await page.getByRole('link', { name: 'reviews/grok-ce-code-review-01.md' }).click();
  await page.waitForSelector('.primary-markdown');
  assert.match(page.url(), /\/documents\/reviews\/grok-ce-code-review-01\.md$/);
  await page.screenshot({ path: `${root}test-results/desktop-document.png`, fullPage: true });
  await page.goBack();
  await page.waitForSelector('#workspace-snapshot-documents');

  await open(page, '/archive');
  assert.equal(await page.locator('article.task-row').count(), 10);
  await page.getByRole('link', { name: 'OAuth-first CLI authentication' }).click();
  await page.waitForSelector('h1');
  assert.match(await page.locator('h1').first().innerText(), /OAuth-first CLI authentication/);
  await page.goBack();
  await page.waitForSelector('article.task-row');
  assert.equal(await page.locator('article.task-row').count(), 10);

  await open(page, '/board/all/attention');
  assert.equal(await page.locator('article.kanban-card').count(), 1);
  await open(page, '/board/all/waiting');
  assert.equal(await page.locator('article.kanban-card').count(), 1);
  await open(page, '/board/hive/attention');
  assert.equal(await page.locator('article.kanban-card').count(), 1);

  await open(page, '/done');
  assert.equal(await page.locator('article.kanban-card').count(), 10);

  await open(page, '/patrol');
  assert.equal(await page.locator('article.patrol-row').count(), 3);
  await open(page, '/digest/2026-09-15');
  assert.equal(await page.locator('li.digest-item').count(), 8);
  await open(page, '/honeycombs/workflows');
  assert.equal(await page.locator('article.workflow-row').count(), 5);
  await open(page, '/honeycombs/modules');
  assert.equal(await page.locator('article.module-row').count(), 1);
  await open(page, '/repos');
  assert.equal(await page.locator('article.repo-row').count(), 5);

  assert.deepEqual(external, []);
  assert.deepEqual(sockets, []);
  assert.deepEqual(errors, []);
  await ctx.close();
});

test('saved-state explanations and independent sessions never write local state', async () => {
  const ctx = await context();
  const page = await ctx.newPage();
  await open(page, '/tasks/hive/build-a-patrol-native-self-260829-cc36');
  await page.getByRole('button', { name: 'Answer this question' }).first().click();
  const note = page.locator('#snapshot-action-note');
  assert.equal(await note.isVisible(), true);
  assert.match(await note.innerText(), /requires a running Hive installation/);
  assert.equal(await page.evaluate(() => [localStorage.length, sessionStorage.length].join(',')), '0,0');
  await page.screenshot({ path: `${root}test-results/desktop-action-note.png` });

  const second = await context();
  const other = await second.newPage();
  await open(other);
  assert.equal(await other.locator('article.kanban-card').count(), 2);
  assert.equal(await other.evaluate(() => [localStorage.length, sessionStorage.length].join(',')), '0,0');
  await second.close();
  await ctx.close();
});

test('unknown routes stay 404 and missing documents are not fabricated', async () => {
  const ctx = await context();
  const page = await ctx.newPage();
  const response = await page.goto(`${base}/tasks/hive/not-a-real-task`);
  assert.equal(response.status(), 404);
  assert.match(await page.locator('body').innerText(), /not part of the saved snapshot/i);
  await ctx.close();
});

test('crawls every exported route and carries no subscriber or operator material', async () => {
  const ctx = await context();
  const page = await ctx.newPage();
  const manifest = JSON.parse(await readFile(`${root}dist/routes.json`, 'utf8'));
  const external = [];
  page.on('request', request => { if (!request.url().startsWith(base)) external.push(request.url()); });
  for (const route of manifest.routes) {
    const response = await page.request.get(`${base}${route.path}`);
    assert.equal(response.status(), 200, `${route.path} did not load`);
    const html = await response.text();
    assert.doesNotMatch(html, /\/home\/|asterio|writero|hive-private/);
    assert.doesNotMatch(html, /email_key|ghp_[A-Za-z0-9]{20,}/);
    for (const match of html.matchAll(/(?:href|src)="(https?:[^"]+)"/g)) {
      assert.match(match[1], /^https:\/\/(?:github\.com|hivecli\.sh)(?:\/|$)/, `${route.path} references ${match[1]}`);
    }
  }
  const privacy = await page.request.get(`${base}/privacy.html`);
  assert.equal(privacy.status(), 200);
  assert.match(await privacy.text(), /waitlist/i);
  assert.deepEqual(external, []);
  await ctx.close();
});

test('mobile: long plan and review documents do not overflow, keyboard action notice works', async () => {
  const ctx = await context({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  await open(page, `${leadTask}/documents/plan.md`);
  await page.waitForSelector('.primary-markdown');
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
  await page.screenshot({ path: `${root}test-results/mobile-document.png`, fullPage: true });

  await open(page, leadTask);
  const answer = page.getByRole('button', { name: 'Answer this question' });
  if (await answer.count()) {
    await answer.first().focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('#snapshot-action-note').isVisible(), true);
  }
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
  await page.screenshot({ path: `${root}test-results/mobile-task.png`, fullPage: true });
  await ctx.close();
});

test('waitlist: durable success, lost response, fresh-token retry and unavailable storage', async () => {
  const ctx = await context(); const page = await ctx.newPage();
  await open(page);
  await page.getByRole('button', { name: 'Join Hive Cloud waitlist', exact: true }).first().click();
  await page.getByLabel('Email address', { exact: true }).fill('browser@example.com');
  await page.waitForFunction(() => !document.getElementById('waitlist-submit').disabled);
  loseResponse = true; submittedTokens = [];
  await page.locator('#waitlist-submit').click();
  await page.waitForFunction(() => document.getElementById('waitlist-status').textContent.includes('couldn’t confirm'));
  assert.equal(await page.getByLabel('Email address', { exact: true }).inputValue(), 'browser@example.com');
  await page.screenshot({ path: `${root}test-results/waitlist-retry.png` });
  await page.waitForFunction(() => !document.getElementById('waitlist-submit').disabled);
  await page.locator('#waitlist-submit').click();
  await page.waitForFunction(() => document.getElementById('waitlist-status').textContent.includes('You’re on the list'));
  assert.equal(new Set(submittedTokens).size, 2);
  assert.equal((await db.prepare('SELECT COUNT(*) AS count FROM waitlist WHERE email_key = ?').bind('browser@example.com').first()).count, 1);
  await page.screenshot({ path: `${root}test-results/waitlist-success.png` });
  await page.keyboard.press('Escape');
  assert.equal(await page.locator('[data-waitlist-open]').first().evaluate(el => el === document.activeElement), true);
  failWrite = true;
  await page.getByRole('button', { name: 'Join Hive Cloud waitlist', exact: true }).first().click();
  await page.getByLabel('Email address', { exact: true }).fill('failed@example.com');
  await page.waitForFunction(() => !document.getElementById('waitlist-submit').disabled);
  await page.locator('#waitlist-submit').click();
  await page.waitForFunction(() => document.getElementById('waitlist-status').textContent.includes('couldn’t confirm'));
  failWrite = false;
  assert.equal((await db.prepare('SELECT COUNT(*) AS count FROM waitlist WHERE email_key = ?').bind('failed@example.com').first()).count, 0);
  await ctx.close();
});

test('verification expiring during save does not discard successful response or leave form busy', async () => {
  const ctx = await context(); const page = await ctx.newPage();
  await open(page);
  await page.getByRole('button', { name: 'Join Hive Cloud waitlist', exact: true }).first().click();
  await page.getByLabel('Email address', { exact: true }).fill('expiry@example.com');
  await page.waitForFunction(() => !document.getElementById('waitlist-submit').disabled);
  delayWrite = true;
  await page.locator('#waitlist-submit').click();
  await page.evaluate(() => window.challengeOptions['expired-callback']());
  await page.waitForFunction(() => document.getElementById('waitlist-status').textContent.includes('You’re on the list'));
  delayWrite = false;
  assert.equal(await page.locator('#waitlist-form').getAttribute('aria-busy'), null);
  assert.equal((await db.prepare('SELECT COUNT(*) AS count FROM waitlist WHERE email_key = ?').bind('expiry@example.com').first()).count, 1);
  await ctx.close();
});
