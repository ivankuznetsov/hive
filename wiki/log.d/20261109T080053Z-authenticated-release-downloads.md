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
  `GITHUB_TOKEN: ${{ github.token }}`.
- cosign: a first attempt pinned cosign-installer to v4.1.3 for its retry. PR CI
  still failed: 6 anonymous 504s, then exit 22. The three jobs now use the
  local composite action `.github/actions/install-cosign`, which runs
  `gh release download v2.5.2 --repo sigstore/cosign` authenticated with the
  job token. It makes 5 attempts with 5/10/20/40s backoff and checks a pinned
  SHA-256 for linux amd64 `bcfeae05…` and arm64 `2cbcea18…`, taken from
  upstream `cosign_checksums.txt` and matching cosign-installer v3's bootstrap
  pins. It then runs `chmod +x` and adds the binary to `$GITHUB_PATH`. The
  cosign download is now authenticated.
- Pages: [[operating]], [[testing]], [[gaps]].
