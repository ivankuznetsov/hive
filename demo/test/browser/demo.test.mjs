import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { signup } from '../../worker/index.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
let server, base, browser, mf, db, loseResponse = false, failWrite = false, delayWrite = false;
let submittedTokens = [];
const challengeJS = `window.turnstile={render(container, options){window.challengeOptions=options;const id=String(++window.challengeCount);setTimeout(()=>options.callback('token-'+id),0);return id},remove(){}};window.challengeCount=0;`;
const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml' };

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
      let path = resolve(`${root}dist`, `.${new URL(req.url, base).pathname}`);
      if (new URL(req.url, base).pathname === '/') path = `${root}dist/index.html`;
      if (!path.startsWith(`${root}dist${sep}`)) { res.writeHead(404); res.end(); return; }
      let data = await readFile(path);
      if (path.endsWith('/index.html')) {
        data = data.toString().replace(/<script id="demo-config" type="application\/json">.*?<\/script>/,
          '<script id="demo-config" type="application/json">{"turnstileSiteKey":"fixture","waitlistEnabled":true}</script>');
      }
      res.writeHead(200, { 'content-type': types[extname(path)] || 'application/octet-stream' }); res.end(data);
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
async function loaded(page) { await page.waitForFunction(() => !document.getElementById('demo-content').hasAttribute('aria-busy') && document.getElementById('demo-reset').hidden === false); }
async function visitTask(page, slug = 'dark-mode', panel = 'overview') {
  await page.evaluate(hash => { location.hash = hash; }, `#/task/${slug}/${panel}`);
  await page.waitForFunction(() => document.getElementById('demo-status').textContent.includes('·'));
  await loaded(page);
}
async function clickNext(page) {
  const previous = await page.evaluate(() => sessionStorage.getItem('hive-demo-v1'));
  await page.getByRole('button', { name: 'Next demo step', exact: true }).click();
  await page.waitForFunction(old => sessionStorage.getItem('hive-demo-v1') !== old, previous);
  await loaded(page);
}

test('desktop: real board, both coherent branches, history/reset, isolated sessions, no live connections', async () => {
  const ctx = await context({ viewport: { width: 1440, height: 1000 } });
  const page = await ctx.newPage();
  const external = [], sockets = [], errors = [];
  page.on('request', request => { if (!request.url().startsWith(base)) external.push(request.url()); });
  page.on('websocket', socket => sockets.push(socket.url()));
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(base); await loaded(page);
  assert.equal(await page.locator('.kanban-card').count(), 4);
  assert.equal(await page.locator('form[action^="/tasks"], turbo-frame, turbo-stream').count(), 0);
  await page.screenshot({ path: `${root}test-results/desktop-board.png`, fullPage: true });
  await page.getByRole('link', { name: 'Follow the dark-mode task →' }).click(); await loaded(page);
  await page.getByRole('button', { name: 'Follow system setting', exact: true }).click(); await loaded(page);
  assert.equal(await page.evaluate(() => sessionStorage.getItem('hive-demo-v1')), 'system-plan');
  await clickNext(page); await clickNext(page);
  await visitTask(page, 'dark-mode', 'diff');
  await page.waitForSelector('.diff-result');
  assert.match(await page.locator('#demo-content').innerText(), /matchMedia/);
  await page.screenshot({ path: `${root}test-results/desktop-review.png`, fullPage: true });
  await clickNext(page);
  assert.equal(await page.getByRole('button', { name: 'Join Hive Cloud waitlist', exact: true }).count(), 2); // header and completion prompt
  await visitTask(page, 'dark-mode', 'overview');
  await page.waitForFunction(() => document.getElementById('demo-content').textContent.includes('Dark mode is ready'));
  await page.screenshot({ path: `${root}test-results/desktop-completed.png`, fullPage: true });
  await page.reload(); await loaded(page);
  assert.equal(await page.evaluate(() => sessionStorage.getItem('hive-demo-v1')), 'system-completed');
  await page.goBack(); await loaded(page);
  assert.equal(await page.evaluate(() => sessionStorage.getItem('hive-demo-v1')), 'system-completed');
  const other = await browser.newContext(); const second = await other.newPage(); await second.goto(base); await loaded(second);
  assert.match(await second.locator('.kanban-card[data-task-slug="dark-mode"]').innerText(), /Needs your input/);
  await other.close();
  await page.getByRole('button', { name: 'Reset demo', exact: true }).click(); await loaded(page);
  await visitTask(page, 'dark-mode', 'diff');
  await page.waitForURL('**/#/task/dark-mode/overview');
  await page.getByRole('button', { name: 'Use a manual switch', exact: true }).click(); await loaded(page);
  await clickNext(page); await clickNext(page);
  await visitTask(page, 'dark-mode', 'diff'); await page.waitForSelector('.diff-result');
  assert.doesNotMatch(await page.locator('#demo-content').innerText(), /matchMedia/);
  await clickNext(page);
  const urls = await page.getByRole('link', { name: 'Run locally ↗', exact: true }).evaluateAll(links => links.map(link => link.href));
  assert.ok(urls.length >= 2 && urls.every(url => url === 'https://hivecli.sh/'));
  assert.deepEqual(external, []); assert.deepEqual(sockets, []); assert.deepEqual(errors, []);
  await ctx.close();
});

test('waitlist: durable success, lost response, fresh-token retry and unavailable storage', async () => {
  const ctx = await context(); const page = await ctx.newPage();
  await page.goto(base); await loaded(page);
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

test('mobile keyboard flow and unavailable browser storage', async () => {
  const ctx = await context({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await ctx.addInitScript(() => { Object.defineProperty(window, 'sessionStorage', { get() { throw new Error('storage unavailable'); } }); });
  const page = await ctx.newPage(); await page.goto(base); await loaded(page);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({ path: `${root}test-results/mobile-board.png`, fullPage: true });
  await page.getByRole('link', { name: 'Follow the dark-mode task →' }).focus(); await page.keyboard.press('Enter'); await loaded(page);
  await page.getByRole('button', { name: 'Use a manual switch', exact: true }).focus(); await page.keyboard.press('Enter'); await loaded(page);
  await page.waitForSelector('button:has-text("Next demo step")');
  await page.screenshot({ path: `${root}test-results/mobile-plan.png`, fullPage: true });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.getByRole('button', { name: 'Reset demo', exact: true }).click(); await loaded(page);
  assert.equal(await page.locator('.kanban-card').count(), 4);
  await ctx.close();
});

test('verification expiring during save does not discard successful response or leave form busy', async () => {
  const ctx = await context(); const page = await ctx.newPage();
  await page.goto(base); await loaded(page);
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
