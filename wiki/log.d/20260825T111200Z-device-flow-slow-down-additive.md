# Device flow: `slow_down` is additive (RFC 8628 §3.5), not absolute

Date: 2026-08-25
Area: lib/hive/web/github_auth.rb, web/app/controllers/sessions_controller.rb

## What changed

`GithubAuth#poll_device_flow` used to map GitHub's `slow_down` token-endpoint
response to `{ state: :slow_down, interval: body.fetch("interval", 5).to_i }`,
treating it as an absolute server-supplied interval. RFC 8628 §3.5 defines
`slow_down` as an ADDITIVE signal: raise your current polling interval by 5
seconds. GitHub's response typically carries no `interval` member at all, so a
flow started at interval 5 stayed stuck at 5 after `slow_down` instead of back-
ing off to 10.

Now:

- `GithubAuth` exposes `SLOW_DOWN_PENALTY = 5` and returns
  `{ state: :slow_down, increase_by: SLOW_DOWN_PENALTY }`, ignoring any payload
  `interval`.
- `SessionsController#wait` applies it additively:
  `device["interval"] += result.fetch(:increase_by)` before recomputing
  `next_poll_at`.

## Tests

- `test/unit/web/github_auth_test.rb`: slow_down maps to the fixed +5 penalty
  with or without an `interval` member in the payload.
- `web/test/integration/sessions_flow_test.rb`: a flow started at interval 5
  that receives `slow_down` re-gates its next poll at +10 seconds.
