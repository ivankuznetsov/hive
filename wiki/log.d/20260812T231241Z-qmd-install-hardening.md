# Harden managed QMD installation and prefix discovery

Pinned the managed installer default to `@tobilu/qmd@2.5.3` and its published
sha512 integrity. Custom QMD selections now require an exact version of the
same package plus an explicit integrity value; arbitrary npm specs fail before
network or install work. The installer downloads the exact tarball once,
verifies its local digest, and installs and health-checks it in a sibling
staging tree. Native failures and bounded-subprocess timeouts keep the previous
managed QMD intact, so optional repair cannot publish or leave behind an
ABI-broken update. The bounded staging startup probe also supplies the version
reported after activation, avoiding a second unbounded executable invocation.

Replaced GNU-only QMD-link canonicalization with Ruby `File.realpath` and
normalizes a real-install prefix to an absolute path before deriving install
locations or writing `install-prefix`. Added installer regressions for the
package/integrity boundary, rebuild and native-probe failures, macOS-style
`readlink -f` absence, startup timeout cleanup, and relative-prefix sidecars.
Fixes #209, #210, #211, and #212.
