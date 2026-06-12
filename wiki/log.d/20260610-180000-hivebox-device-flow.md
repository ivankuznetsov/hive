## 2026-06-10 — hivebox GitHub sign-in switched to OAuth device flow

The web gate's authorization-code web flow (per-operator OAuth app, callback
URL coupled to `web.origin`, `HIVEBOX_GITHUB_CLIENT_SECRET`) is replaced by
the device flow (RFC 8628): `POST /auth/github` requests a user code,
`GET /auth/github/wait` displays it and polls GitHub at the stated interval
(one poll per render, `slow_down`-aware). No callback URL or client secret
exist; `web.github.client_id` defaults to the shared hivebox OAuth app and
stays overridable. Owner-only gating, session renewal, and 403 semantics are
unchanged; GitHub transport failures now map to `Hive::Error` (friendly 422).
Recorded as ADR-036 in [[decisions]]; details in [[commands/web]] and
[[modules/config]].
