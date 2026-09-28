# Command-receipt compatibility candidate proof

Proof date: 2026-09-28.

- Source baseline: `f3de256100aaa9cb4dbc6f9bc9b0b6f8901b314d`
- Base schema v2
- Base schema SHA-256: `92cbd2aaa9f77ff9c294280d18116928d23f727430466a6306baf6ad08385cf0`
- Narrow source patch: `docs/implementation/command-receipt-compatibility.patch`
- Compatibility patch SHA-256: `d2b6a51eb5b3341555d57f8ec916aa995cb26786551602e70a29b65e4379915e`
- Candidate build output: `hive-cli-command-receipt-compat-candidate.gem` (retained outside Git)
- Candidate SHA-256: `ea14234d40d7efc995164ed9590ce7817a04d9ce2a40350577c3d852dea71c34`
- Pinned `agent-cli-runtime` candidate SHA-256:
  `e7b71c6b5607760c41297dcd63de0ed5f441fbd258d650c10387424e75f55f81`
- Extension schema SHA-256: `a108a7018f7e4b0d9e83674bda6457ac0d2c875539c1a7ecd8a95277546b4a3d`

The candidate is a local rollback proof artifact, not a release or a version
decision, and its binary is deliberately not committed. Its only source change
teaches base-schema-v2 validation to accept either no receipt extension or the exact
closed extension object inventory and checksum. Partial, altered, or unknown
objects still fail closed.

The artifact was built from a clean archive of the pinned baseline after the
recorded patch applied cleanly. The patch inventory was checked against all 27
objects in the frozen migration manifest. `sha256sum --check --strict` verified
the packaged bytes before an isolated `gem install --install-dir`; the locally
built pinned `agent-cli-runtime` dependency was installed into the same
isolated prefix.

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
