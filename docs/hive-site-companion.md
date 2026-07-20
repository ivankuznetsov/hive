# Hive web website companion handoff

Hive and `hive-site` are independently versioned. The Hive implementation is
complete only when a separate, linked `hive-site` pull request mirrors the
native-first contract below. Do not import these docs at site build time, merge
either pull request automatically, or deploy the site as part of the source
change.

## Pages to update

- `index.md`
- `_includes/landing/hero.html`
- `_includes/landing/install.html`
- `_includes/landing/fit.html`
- `_includes/landing/cards.html`
- `_includes/landing/cta.html`
- `docs/index.md`
- `docs/getting-started.md`
- `docs/configuration.md`
- `docs/operating.md`
- `docs/commands/index.md`
- new `docs/commands/setup.md`
- new `docs/commands/web.md`
- `box/index.md` and `_includes/box/**` only where ordinary-page links or
  positioning need adjustment

## Content contract

Ordinary landing, install, getting-started, and command pages must lead with
`hive setup` as the native Linux/macOS first run. Explain that it installs,
enables, starts, and probes the per-user Hive web service and reports the
effective URL plus installed, enabled, running, and ready state. The untouched
configuration stays at `http://127.0.0.1:4567`; setup never creates LAN/public
binding or Tailscale exposure and only observes a pre-existing explicitly
gated non-loopback choice.

Document `hive setup --no-service` as the zero-web-service-mutation opt-out,
`hive setup --no-bootstrap` as diagnose-only, bare `hive web` as the blocking
foreground server, `hive web status --json` as read-only state, and
`hive web install --force` as explicit drift repair. The command pages should
name `hive-setup.v1`, `hive-web-status.v1`, and `hive-web-install.v1` and keep
installed, enabled, running, manager availability, URL, and readiness distinct.

Windows guidance should offer WSL with systemd for native Hive web or Hivebox
through Docker Desktop. Ordinary pages need one concise chooser: choose Hivebox
for container isolation, multiple local instances, containment of untrusted
agents, or reproducible server/NAS deployment. Keep the Box section's complete
shell/PowerShell installation, upgrade, and troubleshooting material.

Configuration pages must name the canonical `HIVE_WEB_APP_DIR`,
`HIVE_WEB_ORIGIN`, `HIVE_WEB_STORAGE_DIR`, `HIVE_WEB_LOCAL_LOOPBACK`,
`HIVE_WEB_DIFF_TIMEOUT_SEC`, and `HIVE_WEB_CLONE_TIMEOUT_SEC` settings. The six
corresponding native-web `HIVEBOX_*` aliases remain accepted with migration
warnings through the next major release; canonical values win. Container-only
Hivebox variables remain canonical and quiet.

Package guidance must explain that released Hive web bundles use the installed
`hive-cli` package root and are authenticated through the release's
cosign-signed checksum manifest before extraction. A custom remote
`HIVE_WEB_BUNDLE_URL` requires an exact `HIVE_WEB_BUNDLE_SHA256`.

Reject maintained-site claims that Hive is TUI-only, has no web app, or uses
Docker as the ordinary golden path. Historical material and the dedicated Box
section remain explicit allowlists, not targets for broad rewriting.

## Verification and delivery

From a clean `hive-site` worktree based on its current main branch, run:

```bash
bundle exec jekyll build
npx -y pagefind@^1 --site _site
```

Review the rendered landing, setup, web, configuration, operating, and Box
pages; check internal links and generated AI-native docs. Open a non-draft PR,
link it to the Hive PR in both descriptions, and leave both open without merge,
auto-merge, version bump, publication, or Cloudflare deployment.

## Hive PR release-note block

Copy this block into the Hive PR description for later promotion into the next
explicitly authorized versioned changelog section:

> Native Hive web is now the default local browser experience on supported
> Linux and macOS installations. `hive setup` installs, starts, and probes the
> managed loopback service and reports its effective URL and distinct service
> state; use `--no-service` to opt out or bare `hive web` for a foreground
> server. Managed release bundles now work from installed Homebrew/AUR-style
> package roots and are authenticated before extraction. The six shared-app
> settings are canonical under `HIVE_WEB_*`; their named native-web
> `HIVEBOX_*` aliases continue to work with migration warnings through the next
> major release. Hivebox remains the supported Docker distribution for
> isolation, multiple instances, untrusted-agent containment, and reproducible
> server/NAS deployment. Setup never creates or widens network exposure.
