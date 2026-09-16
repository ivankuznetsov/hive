# Hive interactive demo

A separate website for hivedev.ai, built from the real Hive Web board and task
templates. All tasks and evidence are fictional. Browser interactions choose
prepared states; no Rails server, daemon, provider, GitHub connection, or agent
runs behind the public demo. Only the Cloud waitlist needs a Worker and D1.

## Local preview

Requires Ruby 3.4 with the `web/Gemfile` bundle, Node 22+, and npm.

```sh
cd web
bundle install
cd ../demo
npm ci
npm run build
npm run dev
```

Open http://127.0.0.1:8791. The default build deliberately disables email
collection and says so in the form. The demo remains fully interactive.
The checked-in Wrangler database ID is a local placeholder, not a remote binding.
No deploy command or automatic publication is part of the build.
Stop and restart `npm run dev` after rebuilding: the build replaces its generated
asset directory, so an already-running Wrangler watcher may need to reopen it.

## Verification

```sh
cd web
bundle exec rails test test/integration/demo_export_test.rb
cd ../demo
npm test
npm run build
npx playwright install chromium
npm run test:browser
```

The browser tests start their own local HTTP server and real Miniflare D1
database. They substitute only Turnstile, including token expiry, and simulate a
truncated response after a successful write. No provider or email service is
contacted. Screenshots go into ignored `test-results/`. For Linux CI, install
Chromium with `npx playwright install --with-deps chromium`.

The Wrangler/Miniflare pair is pinned together: this Wrangler release depends on
Miniflare 5 alpha. Tests use its supplied v4 options converter; the lockfile pins
the exact runtime. Do not downgrade to an older vulnerable toolchain to avoid
the converter.

## Data and rendering

- `scenarios/notebook.json`: four tasks and both dark-mode answer branches.
- `../web/script/export_demo.rb`: isolated, build-only Rails view renderer.
- `../web/script/support/demo/exporter.rb`: actual board, summary, Markdown result,
  and eager diff rendering with a restrictive HTML allowlist.
- `src/`: accessible demo shell, navigation, story controls, and waitlist form.
- `worker/index.mjs`: same-origin signup handler; no public list/read endpoint.
- `migrations/0001_waitlist.sql`: unique email key and minimal signup metadata.
- `dist/`: generated public files only; recreated on each build.

`manifest.json` records the source commit and schema version, maps nine prepared
states to static fragments, and names fingerprinted Hive CSS. Rebuild from a
clean, reviewed commit when refreshing the published demo. Do not edit `dist/`.
New active controls or external asset references in a shared template fail the
export rather than silently reconnecting the demo to a live application.

Progress is stored in sessionStorage (memory if unavailable). Back/Forward
changes the selected task/panel, not workflow progress. Reset restores the
initial board. A stale branch panel falls back to Overview. Email is never saved
in browser storage or URLs; resetting the story does not remove a signup.

## Preparing an authorized deployment

Approved launch inputs (2026-09-16): `hivedev.ai`, privacy/removal contact
`ivan@ikuznetsov.com`, retention until launch with a maximum of 12 months after
signup and earlier removal on request. Public build values are checked into
`production.env`; the Turnstile secret exists only in the Cloudflare Worker.

The `production` Wrangler environment binds dedicated D1 database
`hivedev-demo-production`; migration `0001_waitlist.sql` is applied remotely.
Default commands continue to use the local placeholder database. Production
updates use:

```sh
npm run build:production
npx wrangler deploy --env production --dry-run
npx wrangler deploy --env production
```

Before publishing, verify hivedev.ai ownership and its existing service. Use a
dedicated Worker and dedicated D1 database; preserve hivecli.sh and any existing
hivedev deployment. Configure separate preview and production bindings and
origins. Do not share the production database with preview.

1. After release authorization, provision the dedicated D1 database, replace the
   placeholder binding in the intended environment, and apply the migration to
   that environment. The local command is
   `npx wrangler d1 migrations apply DB --local`; remote migrations are a separate
   explicit launch action.
2. Set `SITE_ORIGIN` to the exact public origin and `SIGNUP_COPY_REVISION` to the
   approved notice revision. Store `TURNSTILE_SECRET` as a Worker secret. Create
   a Turnstile widget restricted to the intended hostname; the Worker also checks
   returned hostname and action `waitlist`. Use separate widget settings for
   preview. Missing configuration fails closed.
3. Build with `DEMO_TURNSTILE_SITE_KEY`, `DEMO_PRIVACY_CONTACT` (email), and
   `DEMO_PRIVACY_RETENTION` (approved plain-language retention text). These are
   public values. The generated privacy notice states purpose, stored data,
   Cloudflare use, retention, and removal contact. Confirm the operator/contact
   and retention policy before enabling public collection. Without these values,
   the default preview collects nothing. Never place the secret in build values.
4. Deploy the reviewed bundle to the dedicated Worker, bind hivedev.ai, and enable
   only the intended public route. Static content is served asset-first; only
   `/api/waitlist` runs Worker code. Keep unknown paths as true 404s.
5. Verify the board, both scripted branches, mobile view, both installation
   links, a synthetic signup plus authenticated D1 readback, duplicate handling,
   and privacy notice. Delete the synthetic record. Watch request errors during
   the initial verification window without logging email bodies or tokens.

There is no email delivery in v1. Signup success means the email is durably
recorded for future Cloud availability updates, not that access was granted.
Turnstile is loaded only when the signup dialog is opened. A verification or
storage outage produces retry feedback while browsing continues normally.

## Operating the list and rollback

Use authenticated Cloudflare D1 tooling to export or delete records. There is no
unauthenticated administration endpoint. For a local list inspect with:

```sh
npx wrangler d1 execute DB --local --command 'SELECT id, email, created_at FROM waitlist ORDER BY id'
```

Remote exports contain personal data: use an operator-controlled destination,
apply the declared retention policy, and honor removal requests through the
configured contact. Match deletion by normalized `email_key` using a bound
parameter or correctly quoted operator SQL; don't interpolate untrusted email
text into shell commands. Plus-addresses are preserved; case and outer whitespace
are ignored for duplicate detection.

If the published bundle regresses navigation or signup handling, restore the
previous Worker/assets deployment and verify the public routes again. Preserve
the D1 database and its records: an application rollback must not roll back or
delete the subscriber list. If signup is broken, disable collection in a rebuilt
bundle until storage/verification is healthy; never fake a success response.

Retention operations: remove the waitlist when Hive Cloud launches, and delete
rows at their 12-month deadline (match `created_at` against the current timestamp
minus 12 months). This deployment does not install a scheduled cleanup job;
retention and earlier email removal requests are operator responsibilities.
