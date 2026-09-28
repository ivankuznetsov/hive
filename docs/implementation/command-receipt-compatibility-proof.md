# Command-receipt compatibility candidate proof

Proof date: 2026-09-28.

- Source baseline: `f3de256100aaa9cb4dbc6f9bc9b0b6f8901b314d`
- Base schema v2
- Base schema SHA-256: `92cbd2aaa9f77ff9c294280d18116928d23f727430466a6306baf6ad08385cf0`
- Narrow source patch: `docs/implementation/command-receipt-compatibility.patch`
- Compatibility patch SHA-256: `9cab1e4290a1d253401d4841260ff2972618f7bc396a756c3e71b6fb54bca118`
- Candidate build output: `hive-cli-command-receipt-compat-candidate.gem` (retained outside Git)
- Candidate SHA-256: `ea14234d40d7efc995164ed9590ce7817a04d9ce2a40350577c3d852dea71c34`
- Pinned `agent-cli-runtime` candidate SHA-256:
  `e7b71c6b5607760c41297dcd63de0ed5f441fbd258d650c10387424e75f55f81`
- Extension schema SHA-256: `cf2d9423475a3117089f9c92dff976395671c7712995c8c1c446614e9599f8cb`

The recorded candidate predates the installation-capacity aggregate added to
the extension manifest in this review pass. Its checksum remains historical
evidence, but the candidate must be rebuilt and the drill below repeated before
it can qualify the revised manifest.

The candidate is a local rollback proof artifact, not a release or a version
decision, and its binary is deliberately not committed. Its only source change
teaches base-schema-v2 validation to accept either no receipt extension or the exact
closed extension object inventory and checksum. Partial, altered, or unknown
objects still fail closed.

The historical artifact was built from a clean archive of the pinned baseline
after the preceding patch applied cleanly. The current patch inventory is
checked against all 31 objects in the revised frozen migration manifest, but a
new packaged candidate has not yet been built from it. For the historical
drill, `sha256sum --check --strict` verified the packaged bytes before an
isolated `gem install --install-dir`; the locally built pinned
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
  ea14234d40d7efc995164ed9590ce7817a04d9ce2a40350577c3d852dea71c34 \
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
