# Residual review findings · feat/real-hive-snapshot

Accepted during the 2026-09-17 implementation review of the real Hive snapshot
demo. None block the checked-in implementation or its local verification; each
needs a follow-up before or during the operator-gated deployment.

## 1. Module capture forwards the raw native record (P3, advisory)

`demo/script/capture_snapshot.mjs` filters `root-cause-repair` but otherwise
writes the module list record as returned. A field allowlist would make the
public boundary explicit instead of relying on the pattern audit. The current
record is audited and rendered; no operator secret is present in the checked-in
data.

## 2. Capture-only guards are untested (P2)

`taskRowSource` ambiguity, the missing-artifact failure, and the unmerged-PR
check run only in the maintainer capture, which `npm test` and CI never invoke.
`validateSelection`/`validateTaskFile` cover the same rules on checked-in data,
but a regression in the capture helpers would not fail any test. Extract the
guards into `demo/script/lib/` and add fixture tests.

## 3. Export isolation stubs only project discovery (P3)

`web/test/integration/demo_export_test.rb` proves the exporter never consults
`Hive::Config.registered_projects`, but does not fail if a future adapter opens
a socket, shells out, or touches a live runtime. Add a stricter boundary
(blocked HTTP, raising `Process.spawn`) around the export.

## 4. Worker entrypoint dispatch is untested (P3)

`demo/worker/index.mjs` `export default { fetch }` routing and the D1 write
failure branch are not exercised; the waitlist tests call `signup` directly and
the browser harness uses a Node shim. Add a Miniflare `dispatchFetch` test for
`/api/waitlist` routing, the 404 body, and a failing-D1 503.

Source review: `ce-code-review`-style correctness/security/testing pass over
`git diff 9b92b6572f..HEAD`, 2026-09-17.
