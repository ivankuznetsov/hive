# Command-receipt compatibility candidate proof

Proof date: 2026-09-28.

- Source baseline: `f3de256100aaa9cb4dbc6f9bc9b0b6f8901b314d`
- Base schema v2
- Base schema SHA-256: `92cbd2aaa9f77ff9c294280d18116928d23f727430466a6306baf6ad08385cf0`
- Narrow source patch: `docs/implementation/command-receipt-compatibility.patch`
- Compatibility patch SHA-256: `82562752649c00ef78937f4fbcaa1524d5454b7e0ccaf3609194d8e9b1e233a3`
- Candidate build output: `hive-cli-command-receipt-compat-candidate.gem` (retained outside Git)
- Candidate SHA-256: `4ac48a4adb50d3068df71ba204a10ab9839ad7827d8840bb63366d2732c18a9a`
- Pinned `agent-cli-runtime` candidate SHA-256:
  `e7b71c6b5607760c41297dcd63de0ed5f441fbd258d650c10387424e75f55f81`
- Extension schema SHA-256: `ccadc759fea6e2dd2f886fb151ccc3db08f666d5648127f512c40df3767f9dbe`

The candidate is a local rollback proof artifact, not a release or a version
decision, and its binary is deliberately not committed. Its only source change
teaches base-schema-v2 validation to accept either no receipt extension or the exact
closed extension object inventory and checksum. Partial, altered, or unknown
objects still fail closed.

The artifact was built from a clean archive of the pinned baseline after the
recorded patch applied cleanly. The patch inventory was checked against all 31
objects in the frozen migration manifest. `sha256sum --check --strict`
verified the packaged bytes before an isolated `gem install --install-dir`;
the locally built pinned
`agent-cli-runtime` dependency was installed into the same isolated prefix.

The drill used a fresh base-schema-v2 database, installed the current additive
extension, and then ran the packaged candidate against that retained database.
The candidate reported runtime status `ok`, performed a durable global
maintenance dispatch request write/read/remove cycle, and reported status `ok`
again after the current runtime had written a terminal command receipt.
Reopening with the current runtime then replayed that receipt without executing
the command body and reproduced the original structured result
`{"schema":"hive-approve","ok":true,"decision":"approved"}` with the same
public receipt. The extension, installation identity, and receipt remained in
place throughout; no backup restore or schema removal occurred.

Reproduce in an isolated directory after verifying the candidate checksum:

```sh
candidate=${HIVE_COMPAT_CANDIDATE_GEM:?set to the retained candidate path}
printf '%s  %s\n' \
  4ac48a4adb50d3068df71ba204a10ab9839ad7827d8840bb63366d2732c18a9a \
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
