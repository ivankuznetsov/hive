---
title: Interactive public demo
type: reference
source: demo/**, web/script/export_demo.rb, web/script/support/demo/**
created: 2026-09-13
updated: 2026-09-13
tags: [web, demo, waitlist]
---

# Interactive public demo

The independently deployable hivedev.sh demo lives in `demo/`. It reuses Hive Web
templates at build time and exports static HTML fragments. It does not run Hive
agents, a daemon, or Rails in production. The source tree's normal web application
has no demo auth bypass or changed routes.

`npm --prefix demo run build` invokes the isolated Rails view exporter, then
packages the demo shell and public assets. Four fictional Notebook tasks show
input, implementation, review, and completion. Two dark-mode branches advance
through prepared states in the visitor's tab. Reset and browser navigation never
affect another visitor. Actual plans, diffs and evidence panels use existing
Rails templates; fixtures are explicitly sample data, not live work evidence.

The Cloud waitlist is a same-origin Worker endpoint with server-side Turnstile
validation and a dedicated D1 table. An atomic unique email key deduplicates
signups. There are no public list or admin endpoints and no email sending.
The primary CTA opens this form; Run locally links to https://hivecli.sh.

Default local builds disable collection. A public build needs a site key,
approved privacy contact and retention text; the Worker additionally needs its
secret, origin and database binding. Deployments and production provisioning
remain separately authorized actions. See `demo/README.md` for configuration,
verification, operator access and rollback.

Focused checks: `web/test/integration/demo_export_test.rb`, `npm --prefix demo
test`, and `npm --prefix demo run test:browser`. The browser suite exercises real
local D1 with a substituted Turnstile service; screenshots are local ignored
artifacts, not proof of public deployment.
