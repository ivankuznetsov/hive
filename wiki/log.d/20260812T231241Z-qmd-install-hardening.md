# Harden managed QMD installation and prefix discovery

Pinned the managed installer default to `@tobilu/qmd@2.5.3` and its published
sha512 integrity. Package and integrity compatibility inputs must equal those
release-owned values; arbitrary npm specs and caller-selected digests fail
before network or install work. The installer downloads the exact tarball once,
verifies its local digest, and installs and health-checks it in a sibling
staging tree. Native failures and bounded-subprocess timeouts keep the previous
managed QMD intact, so optional repair cannot publish or leave behind an
ABI-broken update. The bounded staging startup probe also supplies the version
reported after activation, avoiding a second unbounded executable invocation.
The authenticated Hive gem now owns a full npm dependency lock, including an
exact `node-gyp`, and staging uses `npm ci --ignore-scripts` against the already
verified QMD tarball. The installer rejects QMD version or integrity overrides
that are not represented by that lock. It builds better-sqlite3 directly from
the integrity-checked package source with local Node headers and offline
node-gyp mode, so neither transitive ranges nor lifecycle-script prebuild
downloads can drift between otherwise identical Hive installs.

Replaced GNU-only QMD-link canonicalization with Ruby `File.realpath` and
normalizes a real-install prefix to an absolute path before deriving install
locations or writing `install-prefix`. Added installer regressions for the
package/integrity boundary, rebuild and native-probe failures, macOS-style
`readlink -f` absence, startup timeout cleanup, locked-closure validation, and
relative-prefix sidecars. Fixes #209, #210, #211, and #212.
