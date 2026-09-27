# Command-receipt compatibility candidate proof

Proof date: 2026-09-27.

- Source baseline: `882b8e9ead2f9cf5321b158fe47648e6a01a2fca`
- Narrow source patch: `docs/implementation/command-receipt-compatibility.patch`
- Compatibility patch SHA-256: `b29a7fd0cb9082aaf34d026c4bb0832177942262ebe76f43d86a1f7ef46a2730`
- Candidate build output: `hive-cli-command-receipt-compat-candidate.gem` (retained outside Git)
- Candidate SHA-256: `cf7eae51b26bdace854d4a40ab681c53ff67aebb1670fc939310ff7fce3ba712`
- Extension schema SHA-256: `cd35003e8cf5f0a720b28ce9af301a95a14c52987a97bbbdd058f2bf04ec9fb5`

The candidate is a local rollback proof artifact, not a release or a version
decision, and its binary is deliberately not committed. Its only source change
teaches base-v1 validation to accept either no receipt extension or the exact
closed extension object inventory and checksum. Partial, altered, or unknown
objects still fail closed.

The artifact was built from a clean archive of the pinned baseline after
applying the recorded patch. `sha256sum --check --strict` verified the packaged
bytes before an isolated `gem install --install-dir`; the locally built pinned
`agent-cli-runtime` dependency was installed into the same isolated prefix.

The drill used a fresh base-v1 database, installed the current additive
extension, and then ran the packaged candidate against that retained database.
The candidate reported runtime status `ok`, performed a durable dispatch
request write/read/remove cycle, and reported status `ok` again after a current
runtime wrote a terminal command receipt. Reopening with the current runtime
then replayed that receipt with the original `approved\n` result. The extension,
installation identity, and receipt remained in place throughout; no backup
restore or schema removal occurred.

Reproduce in an isolated directory after verifying the candidate checksum:

```sh
candidate=${HIVE_COMPAT_CANDIDATE_GEM:?set to the retained candidate path}
printf '%s  %s\n' \
  cf7eae51b26bdace854d4a40ab681c53ff67aebb1670fc939310ff7fce3ba712 \
  "$candidate" | sha256sum --check --strict &&
gem install --local --ignore-dependencies --no-document \
  --install-dir "$PWD/tmp/compat-prefix" "$candidate"
HIVE_HOME="$PWD/tmp/compat-proof-state" \
  "$PWD/tmp/compat-prefix/bin/hive" runtime status --json
```

The recorded candidate checksum and external build output are evidence for Tier
A only. They are not a published, retained distribution and must not be used
for production activation. Tier B
still requires maintainer-selected release coordinates, publication, download
from the authenticated retained location, checksum verification, and the same
drill against those downloaded bytes.
