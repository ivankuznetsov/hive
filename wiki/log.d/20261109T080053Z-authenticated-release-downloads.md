## 2026-11-09 — Authenticated, retrying release downloads for install CI

- Symptom: from ~07:10Z, during GitHub's "Increased timeouts due to surge in
  anonymous users" incident, `install.sh full install smoke` and
  `verify-release.sh (end-to-end behavior)` failed on main and PRs. Either
  `install.sh` got HTTP 504 fetching `SHA256SUMS`, or
  `sigstore/cosign-installer@v3` exited 22 downloading its cosign v2.5.2
  bootstrap.
- `install.sh` and `packaging/verify-release.sh`: every GitHub download now
  uses `--retry 4 --retry-delay 5 --retry-max-time 60`. An optional
  `GITHUB_TOKEN`/`GH_TOKEN` (same order as `packaging/betterleaks.rb`, PR #1626)
  is sent as `Authorization: Bearer` only to `https://github.com` /
  `https://api.github.com`. It is passed through a process-substitution header
  file, so it never appears in argv or logs, and sent only when curl is >= 7.83.
  It is never sent with `--location-trusted`. A 401/403 retries that request
  anonymously. When no token is set, the only change is the retry.
- Workflows: `install-smoke.yml` (`full-smoke`, `verify-release`) and
  `install-verify.yml` (bash channel) pass step-scoped
  `GITHUB_TOKEN: ${{ github.token }}`. cosign-installer is SHA-pinned to v4.1.3
  with `cosign-release: v2.5.2`. That action has no token input, so its
  built-in download retry is what makes it resilient.
- Pages: [[operating]], [[testing]], [[gaps]].
