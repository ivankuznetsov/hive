import { spawnSync } from 'node:child_process';
import { readFile, writeFile, cp, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
await rm(`${root}dist`, { recursive: true, force: true });
const exported = spawnSync('bundle', ['exec', 'ruby', 'script/export_demo.rb'], {
  cwd: fileURLToPath(new URL('../../web/', import.meta.url)), stdio: 'inherit',
  env: { ...process.env, BUNDLE_GEMFILE: fileURLToPath(new URL('../../web/Gemfile', import.meta.url)) }
});
if (exported.status !== 0) process.exit(exported.status || 1);

const manifest = JSON.parse(await readFile(`${root}dist/manifest.json`, 'utf8'));
await cp(`${root}src`, `${root}dist`, { recursive: true });
await cp(fileURLToPath(new URL('../../web/public/icon.svg', import.meta.url)), `${root}dist/icon.svg`);
const initialBoard = await readFile(`${root}dist/${manifest.states[manifest.initial].board}`, 'utf8');
const siteKey = process.env.DEMO_TURNSTILE_SITE_KEY || null;
const contact = process.env.DEMO_PRIVACY_CONTACT || '';
const retention = process.env.DEMO_PRIVACY_RETENTION || '';
const enabled = Boolean(siteKey && contact && retention);
if (siteKey && !enabled) throw new Error('Waitlist builds require DEMO_PRIVACY_CONTACT and DEMO_PRIVACY_RETENTION.');
if (contact && !/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(contact)) throw new Error('Invalid privacy contact email.');
const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');
const config = JSON.stringify({ turnstileSiteKey: siteKey, waitlistEnabled: enabled }).replaceAll('<', '\\u003c');
const shell = await readFile(`${root}src/index.html`, 'utf8');
for (const token of ['<!-- INITIAL_BOARD -->', '<!-- HIVE_STYLESHEET -->', '<!-- DEMO_CONFIG -->']) {
  if (!shell.includes(token)) throw new Error(`Missing shell build token: ${token}`);
}
await writeFile(`${root}dist/index.html`, shell
  .replace('<!-- INITIAL_BOARD -->', initialBoard)
  .replace('<!-- HIVE_STYLESHEET -->', `<link rel="stylesheet" href="/${escape(manifest.stylesheet)}">`)
  .replace('<!-- DEMO_CONFIG -->', `<script id="demo-config" type="application/json">${config}</script>`));

const infoPage = (title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} · Hive</title><link rel="stylesheet" href="/${escape(manifest.stylesheet)}"><link rel="stylesheet" href="/demo.css"></head><body><main class="demo-info"><a href="/">← Back to the demo</a><h1>${title}</h1>${body}</main></body></html>`;
await writeFile(`${root}dist/privacy.html`, infoPage('Hive Cloud waitlist privacy', enabled
  ? `<p>When you join, we store your email address, signup time, and the signup notice revision to notify you about Hive Cloud availability. This form does not create a Hive account.</p><p>The list is stored using Cloudflare D1. Cloudflare Turnstile processes verification data to protect this form from automated abuse. We do not add your demo activity or IP address to the subscriber record.</p><p>Retention: ${escape(retention)}</p><p>For removal or privacy questions, contact <a href="mailto:${escape(contact)}">${escape(contact)}</a>.</p>`
  : '<p>This local preview is not collecting waitlist emails. Operator contact and retention details must be configured before public signup is enabled.</p>'));
await writeFile(`${root}dist/404.html`, infoPage('Page not found', '<p>This page is not part of the demo. Return to the board to explore the example tasks.</p>'));
await writeFile(`${root}dist/_headers`, `/*
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Content-Security-Policy: default-src 'self'; script-src 'self' https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; connect-src 'self' https://challenges.cloudflare.com; style-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'
/manifest.json
  Cache-Control: no-cache
/fragments/*
  Cache-Control: no-cache
`);
console.log(`Built demo from ${manifest.source_commit}. Waitlist ${enabled ? 'configured' : 'disabled (local preview)'}.`);
