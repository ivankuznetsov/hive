# 2026-07-27 — Give the Agent CLI Runtime mirror a scoped Git writer

**Why:** Live dogfooding showed that GitHub rejects a mirror sync commit when
the generated Actions token changes `.github/workflows`, even when the workflow
has `contents: write`. The package projection and build passed, but the final
push could not install canonical administration.

**Change:** Both mirror workflows now authenticate their mirror checkout with
the write-enabled, repository-scoped deploy key stored as
`MIRROR_DEPLOY_KEY`. Sync reduces its generated token to `contents: read`;
release keeps that short-lived token only for ruleset inspection and GitHub
release creation. Tests and operator documentation cover the credential
boundary.

**Boundary:** The deploy key can clone and push only
`ivankuznetsov/agent-cli-runtime`; it grants no Hive or RubyGems authority and
must not be reused. Canonical source, administration, version selection, and
publication remain in Hive.
