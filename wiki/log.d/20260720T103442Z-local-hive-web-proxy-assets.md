# Restore local Hive Web access and assets

- Kept `hive web` as a local browser control plane over the same registry and
  workflow state as the CLI/TUI, distinct from the owner-gated Hivebox product.
- Made loopback authentication use the real socket peer so Tailscale Serve and
  similar localhost proxies do not turn forwarded tailnet addresses into a
  Hivebox login gate. The proxy remains part of the access boundary and must
  restrict/authenticate its clients. Local GitHub connection remains optional
  and never claims `web.github.owner`.
- Made managed web installation precompile and verify production CSS/JavaScript
  manifest graph before atomically activating a bundle, repair same-version
  installs whose assets are missing, and preserve the last working bundle on
  build failure.
- Extended integration, unit, and Docker smoke coverage for forwarded local
  access, product copy/branding, optional GitHub sessions, missing-asset repair,
  and fetching every digest-stamped asset advertised by the login page.
