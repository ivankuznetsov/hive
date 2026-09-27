# Command-receipt compatibility candidate proof

Proof date: 2026-09-27.

- Source baseline: `882b8e9ead2f9cf5321b158fe47648e6a01a2fca`
- Narrow source patch: `docs/implementation/command-receipt-compatibility.patch`
- Candidate: `docs/artifacts/hive-cli-0.7.4-command-receipt-compat-candidate.gem`
- Candidate SHA-256: `84163c17613771f85e6acfcd6c90a31bc21307d971b602f16ab0b29954745102`
- Extension schema SHA-256: `0de7f2bad101616088278812b14c9c50d14a849980963e41cf9779874ca4c9a2`

The candidate retains the pinned baseline's package version because it is a
local rollback proof artifact, not a release or a version decision. Its only
source change teaches base-v1 validation to accept either no receipt extension
or the exact closed extension object inventory and checksum. Partial, altered,
or unknown objects still fail closed.

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
candidate=docs/artifacts/hive-cli-0.7.4-command-receipt-compat-candidate.gem
printf '%s  %s\n' \
  84163c17613771f85e6acfcd6c90a31bc21307d971b602f16ab0b29954745102 \
  "$candidate" | sha256sum --check --strict
gem install --local --ignore-dependencies --no-document \
  --install-dir "$PWD/tmp/compat-prefix" "$candidate"
HIVE_HOME="$PWD/tmp/compat-proof-state" \
  "$PWD/tmp/compat-prefix/bin/hive" runtime status --json
```

The checked-in candidate is evidence for Tier A only. It is not published,
retained distribution and must not be used for production activation. Tier B
still requires maintainer-selected release coordinates, publication, download
from the authenticated retained location, checksum verification, and the same
drill against those downloaded bytes.
