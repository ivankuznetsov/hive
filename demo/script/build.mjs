import { spawnSync } from 'node:child_process';
import { mkdir, readFile, writeFile, cp, rm } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const web = fileURLToPath(new URL('../../web/', import.meta.url));
const dist = join(root, 'dist');

await rm(dist, { recursive: true, force: true });
const exported = spawnSync('bundle', ['exec', 'ruby', 'script/export_demo.rb', dist], {
  cwd: web, stdio: 'inherit',
  env: { ...process.env, BUNDLE_GEMFILE: join(web, 'Gemfile') }
});
if (exported.status !== 0) process.exit(exported.status || 1);

const manifest = JSON.parse(await readFile(join(dist, 'routes.json'), 'utf8'));
for (const asset of ['app.mjs', 'waitlist.mjs', 'demo.css']) {
  await cp(join(root, 'src', asset), join(dist, asset));
}
await cp(join(web, 'public/icon.svg'), join(dist, 'icon.svg'));

const siteKey = process.env.DEMO_TURNSTILE_SITE_KEY || null;
const contact = process.env.DEMO_PRIVACY_CONTACT || '';
const retention = process.env.DEMO_PRIVACY_RETENTION || '';
const enabled = Boolean(siteKey && contact && retention);
if (siteKey && !enabled) throw new Error('Waitlist builds require DEMO_PRIVACY_CONTACT and DEMO_PRIVACY_RETENTION.');
if (contact && !/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(contact)) throw new Error('Invalid privacy contact email.');
const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
const config = JSON.stringify({ turnstileSiteKey: siteKey, waitlistEnabled: enabled }).replaceAll('<', '\\u003c');
const configTag = `<script id="demo-config" type="application/json">${config}</script>`;

for (const route of manifest.routes) {
  const target = join(dist, route.page);
  const page = await readFile(target, 'utf8');
  if (!page.includes('<!-- DEMO_CONFIG -->')) throw new Error(`Page ${route.page} is missing the config slot.`);
  await writeFile(target, page.replace('<!-- DEMO_CONFIG -->', configTag));
}

const infoPage = (title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} · Hive</title><link rel="stylesheet" href="${escape(manifest.stylesheet)}"><link rel="stylesheet" href="/demo.css"></head><body><main class="demo-info"><a href="/">← Back to the snapshot</a><h1>${title}</h1>${body}</main></body></html>`;
await writeFile(join(dist, 'privacy.html'), infoPage('Hive Cloud waitlist privacy', enabled
  ? `<p>When you join, we store your email address, signup time, and the signup notice revision to notify you about Hive Cloud availability. This form does not create a Hive account.</p><p>The list is stored using Cloudflare D1. Cloudflare Turnstile processes verification data to protect this form from automated abuse. We do not add your demo activity or IP address to the subscriber record.</p><p>Retention: ${escape(retention)}</p><p>For removal or privacy questions, contact <a href="mailto:${escape(contact)}">${escape(contact)}</a>.</p>`
  : '<p>This local preview is not collecting waitlist emails. Operator contact and retention details must be configured before public signup is enabled.</p>'));
await writeFile(join(dist, '404.html'), infoPage('Page not found', '<p>This path is not part of the saved snapshot. Every exported route is listed in the snapshot manifest; return to the status board to continue browsing.</p>'));
await writeFile(join(dist, '_headers'), `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Content-Security-Policy: default-src 'self'; script-src 'self' https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; connect-src 'self' https://challenges.cloudflare.com; style-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'
/privacy.html
  Cache-Control: no-cache
`);
console.log(`Built ${manifest.routes.length} snapshot routes from ${manifest.captured_at}. Waitlist ${enabled ? 'configured' : 'disabled (local preview)'}.`);
