---
title: Interactive public demo
type: reference
source: demo/**, web/script/export_demo.rb, web/script/support/demo/**
created: 2026-09-13
updated: 2026-09-17
tags: [web, demo, waitlist, snapshot]
---

# Interactive public demo

The independently deployable hivedev.ai demo lives in `demo/`. It renders the
real Hive Web layout, status board/grid, archive, task workspace, repository,
Honeycombs workflow/module, Patrol, and digest templates against a reviewed,
checked-in public snapshot. It does not run Hive agents, a daemon, or Rails in
production. The source tree's normal web application has no demo auth bypass or
changed routes.

`demo/snapshot/selection.json` is the explicit corpus allowlist; the checked-in
`demo/snapshot/data/`, `documents/`, and `changes/` files are the only public
dataset. `demo/script/capture_snapshot.mjs` is a maintainer-only, read-only
capture that resolves selected tasks from native `hive` projections, verifies
merged pull-request evidence against the public GitHub API, applies explicit
redactions, and fails closed on forbidden content. `demo/script/audit_snapshot.mjs`
reviews the dataset for local paths, credentials, excluded projects, unapproved
URLs, control bytes, and provenance drift. Nothing from the operator
installation is read by a normal build or by CI.

`npm --prefix demo run build` invokes the isolated Rails view exporter in
`web/script/support/demo/`, which builds a canonical path-based route graph
(`/board/<project>/<state>`, `/grid`, `/archive`, `/done`, `/repos`,
`/honeycombs/workflows|modules`, `/patrol`, `/digest/<date>`,
`/tasks/<project>/<slug>[/documents/<name>|/change]`, `/unavailable/*`) and
renders each route through adapted real templates. Fragments pass a structural
allowlist: live forms, streams, lazy frames, remote media, unresolved paths,
executable schemes, and unreviewed external links fail the export or become
visible notes. Render-time helpers that would mutate live Hive raise. Unknown
paths stay 404, and saved-state action buttons only explain the missing local or
Cloud runtime.

The Cloud waitlist is a same-origin Worker endpoint with server-side Turnstile
validation and a dedicated D1 table. An atomic unique email key deduplicates
signups. There are no public list or admin endpoints and no email sending.
The primary CTA opens this form; Run locally links to https://hivecli.sh.

Default local builds disable collection. A public build needs a site key,
approved privacy contact and retention text; the Worker additionally needs its
secret, origin and database binding. Deployments and production provisioning
remain separately authorized actions. See `demo/README.md` for configuration,
verification, operator access and rollback.

Production uses `hivedev.ai`, dedicated Worker and D1 database
`hivedev-demo-production`, and hostname-restricted Turnstile. The production
Wrangler environment enables logs and traces. `npm --prefix demo run
build:production` loads checked-in public configuration; secrets stay in
Cloudflare. The approved privacy contact is `ivan@ikuznetsov.com`; emails are
retained until launch, capped at 12 months after signup, with earlier removal
on request. Removal is an operator responsibility; no cleanup cron is installed.

Focused checks: `web/test/integration/demo_export_test.rb`, `npm --prefix demo
test`, and `npm --prefix demo run test:browser`. The browser suite exercises real
local D1 with a substituted Turnstile service; screenshots are local ignored
artifacts, not proof of public deployment.
