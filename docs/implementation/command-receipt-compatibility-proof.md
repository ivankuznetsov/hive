# Command-receipt compatibility candidate proof

Proof date: 2026-09-28 (candidate rebuilt and drill repeated against the
current 31-object manifest, including the installation-wide capacity
aggregate).

- Source baseline: `f3de256100aaa9cb4dbc6f9bc9b0b6f8901b314d`
- Base schema v2
- Base schema SHA-256: `92cbd2aaa9f77ff9c294280d18116928d23f727430466a6306baf6ad08385cf0`
- Narrow source patch: `docs/implementation/command-receipt-compatibility.patch`
- Compatibility patch SHA-256: `82562752649c00ef78937f4fbcaa1524d5454b7e0ccaf3609194d8e9b1e233a3`
- Candidate build output: `hive-cli-command-receipt-compat-candidate.gem`
  (hive-cli 0.7.4, retained outside Git)
- Candidate SHA-256: `ddc5ecca37a4fa67329ad022c546d03bee71bf6526f2180838ed32dc765971db`
- Pinned `agent-cli-runtime` 0.2.4 candidate SHA-256:
  `40ca91ad4d24f8802f0d6b8e29fabba1cd508c9bdc8f5b5abe152bc5e7b10f03`
- Extension schema SHA-256: `ccadc759fea6e2dd2f886fb151ccc3db08f666d5648127f512c40df3767f9dbe`
- Build environment: Ruby 3.4.5, RubyGems `gem build` with
  `SOURCE_DATE_EPOCH=1790552263` (the baseline commit time), SQLite 3.53.

The candidate is a local rollback proof artifact, not a release or a version
decision, and its binary is deliberately not committed. Its only source change
teaches base-schema-v2 validation to accept either no receipt extension or the exact
closed extension object inventory and checksum. Partial, altered, or unknown
objects still fail closed.

## Superseded candidate

An earlier candidate (`4ac48a4adb50d3068df71ba204a10ab9839ad7827d8840bb63366d2732c18a9a`,
with `agent-cli-runtime` `e7b71c6b5607760c41297dcd63de0ed5f441fbd258d650c10387424e75f55f81`)
was built before the installation-wide capacity aggregate
(`command_installation_capacity` and the three `command_capacity_installation_*`
triggers) joined the manifest. It is not evidence for the current manifest and
must not be used.

## Inventory check

Before the rebuild, the `COMMAND_RECEIPT_OBJECT_NAMES` block in the current
patch was compared with `Hive::RuntimeControlPlane::CommandSchema::OBJECT_NAMES`
(12 tables, 16 indexes, 3 triggers = 31 objects). The two sets are identical,
including `command_installation_capacity` and
`command_capacity_installation_{insert,update,delete}`, and the patch pins the
current extension checksum `ccadc759…`. The patch therefore needed no change;
`test_compatibility_proof_tracks_schema_patch_and_fail_closed_install_sequence`
enforces the same equality in source.

## Build

The artifact was built from a clean `git archive` of the pinned baseline; the
current patch passed `git apply --check` and applied cleanly. `gem build` then
produced the candidate and the pinned `agent-cli-runtime` from
`components/agent-cli-runtime` of the same archive. With the recorded
`SOURCE_DATE_EPOCH`, a second build reproduced the identical candidate
checksum. `sha256sum --check --strict` verified the packaged bytes before an
isolated `gem install --local --ignore-dependencies --install-dir`; both gems
went into the same fresh prefix, and the drill asserted that `hive-cli` loaded
from that prefix.

## Drill

Every step ran with `env -i` and fresh temporary `HOME`, `XDG_STATE_HOME`,
`XDG_CONFIG_HOME`, and `HIVE_HOME` directories. No live Hive state was read
or written. The candidate ran from the isolated prefix. The current runtime
ran from the PR worktree at `3f21b30f7b` through `bundle exec ruby -Ilib`.
Recorded outcome, in order:

1. Candidate `RuntimeControlPlane::Installation.setup` created a fresh
   base-schema-v2 database (`phase: active`, database `status: ok`). Candidate
   `hive runtime status --json` returned `ok: true`, `schema_version: 2`.
2. Current `CommandSchemaInstallation.install!` installed the additive extension
   (`status: installed`, `version: 2`). `CommandSchema.exact?` was true with
   checksum `ccadc759…`, and the installation id was unchanged. The call used
   drill-only package coordinates (an `example.invalid` location plus the
   candidate checksum) that satisfy the local validator. They are not
   published coordinates, and `PUBLISHED_ROLLBACK_PACKAGE` stays empty.
3. Candidate `hive runtime status --json` against the extended database
   returned `ok: true`, `phase: active`, database `status: ok`, and the same
   installation id.
4. Candidate `DispatchRepository` completed a durable global maintenance
   dispatch cycle: `write_request!(project: "__global__",
   argv: %w[hive daemon install --force])`, `fetch` (state `queued`), presence
   in `pending`, `remove`, and `fetch` returning nil afterwards.
5. Current `CommandOperation` (key `tier-a-compat-drill`, command `approve`)
   executed its body once and committed a terminal receipt in state
   `succeeded`, generation 2, with the result
   `{"schema":"hive-approve","ok":true,"decision":"approved"}`.
6. Candidate `hive runtime status --json` again returned `ok: true`, and a
   second global maintenance write/read/remove cycle succeeded with the receipt
   present.
7. A fresh current-runtime process reopened the database and repeated the same
   keyed operation with a body that raises if executed. The body did not run.
   The replayed result, including the public receipt (same id, generation 2,
   `succeeded`), was byte-for-byte identical to step 5. `CommandSchema.exact?`
   was still true and the installation id was unchanged.
8. Fail-closed control: on a private copy of the database with
   `command_capacity_installation_insert` dropped, candidate
   `hive runtime status --json` refused with `ok: false`, `MigrationRequired`,
   `runtime_code: partial_schema`, and exit 78.

Steps 1–7 passed and step 8 failed closed as designed. The extension,
installation identity, and receipt stayed in place throughout. No backup
restore or schema removal occurred.

## Reproduce

Build from a clean archive and verify the candidate:

```sh
work=$(mktemp -d) && mkdir "$work/src"
git archive f3de256100aaa9cb4dbc6f9bc9b0b6f8901b314d | tar -x -C "$work/src"
(cd "$work/src" &&
  git apply --check "$OLDPWD/docs/implementation/command-receipt-compatibility.patch" &&
  git apply "$OLDPWD/docs/implementation/command-receipt-compatibility.patch" &&
  SOURCE_DATE_EPOCH=1790552263 gem build hive.gemspec \
    -o "$work/hive-cli-command-receipt-compat-candidate.gem" &&
  cd components/agent-cli-runtime &&
  SOURCE_DATE_EPOCH=1790552263 gem build agent-cli-runtime.gemspec \
    -o "$work/agent-cli-runtime-0.2.4.gem")
```

Install in an isolated directory after verifying the candidate checksum:

```sh
candidate=${HIVE_COMPAT_CANDIDATE_GEM:?set to the retained candidate path}
printf '%s  %s\n' \
  ddc5ecca37a4fa67329ad022c546d03bee71bf6526f2180838ed32dc765971db \
  "$candidate" | sha256sum --check --strict &&
gem install --local --ignore-dependencies --no-document \
  --install-dir "$PWD/tmp/compat-prefix" \
  "$(dirname "$candidate")/agent-cli-runtime-0.2.4.gem" "$candidate"
HIVE_HOME="$PWD/tmp/compat-proof-state" \
  GEM_HOME="$PWD/tmp/compat-prefix" \
  GEM_PATH="$PWD/tmp/compat-prefix:$(gem env gempath)" \
  "$PWD/tmp/compat-prefix/bin/hive" _0.7.4_ runtime status --json
```

Then repeat drill steps 1–8 above against that fresh `HIVE_HOME`. Run the
candidate steps with the isolated `GEM_HOME`/`GEM_PATH`, and run the
current-runtime steps from the PR checkout with `bundle exec ruby -Ilib`.

The recorded candidate checksum and external build output are evidence for Tier
A only. They are not a published, retained distribution and must not be used
for production activation. Tier B
still requires maintainer-selected release coordinates, publication, download
from the authenticated retained location, checksum verification, and the same
drill against those downloaded bytes.
