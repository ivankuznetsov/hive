# 2026-11-27 — Switch `release.yml` to local `.github/actions/install-cosign`

**Action:** Replaced `sigstore/cosign-installer@398d4b0eeef1380460a10c8013a76f728fb906ac`
(v3.10.1) in `.github/workflows/release.yml`'s Linux `release-finalize` job
(`ubuntu-24.04`) with Hive's authenticated, SHA-256-pinned composite action
`./.github/actions/install-cosign` (`github-token: ${{ github.token }}`),
eliminating the last `sigstore/cosign-installer` reference across
`.github/workflows/*.yml`. Extended `test/unit/packaging/verify_release_test.rb`
to verify `release-finalize`'s Linux runner, checkout-before-install and
install-before-signing ordering, and absence of `sigstore/cosign-installer` in
every workflow file. Updated [[operating]], [[testing]], and [[gaps]] (noting
the resulting `action_lock_sha256` change for future release-candidate
dispatches).
