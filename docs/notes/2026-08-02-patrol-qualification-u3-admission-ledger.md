# PR #910 U3 Admission Ledger

Captured: 2026-08-02

Donor PR: https://github.com/ivankuznetsov/hive/pull/910

Frozen donor head: `7d14ebb72801706f3029c1ca437d9f2f43825efe`

Admission state: `awaiting_checkpoint_readback_A1_and_exact_head_review`

This ledger contains every finding or finding-shaped observation recovered from
PR #910 exactly once. Donor resolution claims are historical evidence only;
none closes a successor obligation.

## Historical metadata policy

`historical_metadata_unavailable` means the field demonstrably did not exist or
cannot truthfully be bound to an exact committed tree. It must not be replaced
with a nearby implementation or resolution SHA.

The dirty reviews DRA and DRB ran with nominal `HEAD`
`5dde37d89b58078188527c1fa692cfcaf6c2aa96`, plus 966 insertions, 922
deletions, and four untracked files. Their exact reviewed tree therefore has no
Git SHA.

- DRA: archived frozen-diff review A, rollout
  `019fb471-ab09-7d83-a2c6-ec2ba8405ccb`, response line 40207.
- DRB: archived frozen-diff review B, rollout
  `019fb47b-0f92-7862-b079-27f2fe634a0c`, response line 406.
- C5135399829: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5135399829
- C5135403713: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5135403713
- C5135407543: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5135407543
- C5136720627: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5136720627
- C5139610859: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5139610859
- C5139656686: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5139656686
- C5141519827: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5141519827
- C5141877842: https://github.com/ivankuznetsov/hive/pull/910#issuecomment-5141877842

## Owned observations

| # | Source locator | Stable ID | Reviewed SHA | Severity | Owner | Invariant | Status |
|---:|---|---|---|---|---|---|---|
| 1 | C5135399829 / Findings / 1 | `U3-B01` | `4c05eeedaf3013806f9cd4f8908e31c277d97eed` | P2 | U3a | Timestamp spread can falsely qualify repeated decisions from one decision class. | Characterized by donor; pending U3a exact-head proof. |
| 2 | C5135399829 / Findings / 2; C5135407543 / Design / 4 | `U3-B02` | `4c05eeedaf3013806f9cd4f8908e31c277d97eed` | P2 | U3a | Project-local report migration must remain module-owned and must not be mapped onto host-global recovery. | Donor design claimed resolution; pending U3a boundary proof. |
| 3 | DRA / P0 / 1; C5136720627 / Finding ledger / Resolved / 1 | `U3-I01` | `historical_metadata_unavailable` | P0 | U3a | Migration receipt binds to mutable current report bytes, so legitimate report replacement makes later report or cutover conflict. | Donor claimed resolved; pending U3a exact-head review. |
| 4 | DRA / P1 / 1; C5136720627 / Finding ledger / Resolved / 2 | `U3-I02` | `historical_metadata_unavailable` | P1 | operator | Existing v1 `cutover_pending` projects can become permanently fenced with no valid recovery transition. | Donor claimed resolved; pending operator lifecycle follow-up. |
| 5 | C5136720627 / Finding ledger / Safety-resolved / 1; DRA / P1 / 2 | `U3-I03` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | P1 | U3c | Persisted evidence can self-attest current project, candidate, scenario, and artifact bindings without an independent live authority. | Donor claimed fail-closed safety resolution; pending U3c exact-head authority proof. |
| 6 | DRA / P1 / 3; C5136720627 / Finding ledger / Resolved / 3 | `U3-I04` | `historical_metadata_unavailable` | P1 | operator | Active module generation can change after qualification and cutover can enable a different selection with the same configuration digest. | Donor claimed resolved; pending operator cutover-generation proof. |
| 7 | DRA / P1 / 4; C5136720627 / Finding ledger / Resolved / 4 | `U3-I05` | `historical_metadata_unavailable` | P1 | U3a | Report writes bypass the migration authority lock and expected-report CAS, allowing persistence to race an ownership transition. | Donor claimed resolved; pending U3a single-writer proof. |
| 8 | C5136720627 / Finding ledger / Open / 1; DRA / P1 / 5 | `U3-I06` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | P1 | U3c | No production qualification producer existed; only manually staged JSON and test support constructed bindings and bundles. | Open at donor checkpoint; pending U3c installed/live producer proof. |
| 9 | DRA / P2 / 1; C5136720627 / Finding ledger / Resolved / 5 | `U3-I07` | `historical_metadata_unavailable` | P2 | U3a | A partial-lane report can be written but cannot be reloaded or completed with the missing lane. | Donor claimed resolved; pending U3a partial-report proof. |
| 10 | DRA / P2 / 2; C5136720627 / Finding ledger / Resolved / 6 | `U3-I08` | `historical_metadata_unavailable` | P2 | U3a | `Report` couples projection, custody, verification, freshness, identity, and migration provenance into one trust-boundary hotspot. | Donor claimed resolved; pending U3a owner/dependency proof. |
| 11 | C5136720627 / Finding ledger / Open / 2; DRA / P2 / 3 | `U3-I09` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | P2 | U3c | Required wiki, log-fragment, and known-gap documentation was absent. | Open at donor checkpoint; U3c is final inherited closing owner, while every successor still documents its own changes. |
| 12 | DRB / 1; C5136720627 / Finding ledger / Resolved / 7 | `U3-I10` | `historical_metadata_unavailable` | P1 | U3a | Normal v1 migration followed by report rebuild causes the same mutable-receipt conflict as `U3-I01`. | Donor claimed resolved; pending U3a exact-head regression proof. |
| 13 | DRB / 2; C5136720627 / Finding ledger / Resolved / 8 | `U3-I11` | `historical_metadata_unavailable` | P1 | U3a | A persisted one-lane report cannot reload or later accept the missing lane, duplicating the `U3-I07` invariant. | Donor claimed resolved; pending U3a exact-head regression proof. |
| 14 | DRB / 3; C5136720627 / Finding ledger / Resolved / 9 | `U3-I12` | `historical_metadata_unavailable` | P1 | operator | Cutover accepts active-selection or source drift when configuration digests remain unchanged. | Donor claimed resolved; pending operator lifecycle proof. |
| 15 | DRB / 4; C5136720627 / Finding ledger / Resolved / 10 | `U3-I13` | `historical_metadata_unavailable` | P1 | U3a | A released, schema-valid v1 success report with `configuration_digest: null` cannot migrate. | Donor claimed resolved; pending U3a released-shape migration proof. |
| 16 | DRB / 5; C5136720627 / Finding ledger / Resolved / 11 | `U3-I14` | `historical_metadata_unavailable` | P2 | U3a | Removing the v1 schema breaks the documented explicit historical-schema lookup contract. | Donor claimed resolved; pending U3a frozen-input-contract proof. |
| 17 | DRB / 6; C5136720627 / Finding ledger / Resolved / 12 | `U3-I15` | `historical_metadata_unavailable` | P2 | U3a | Report migration follows a `.mutation.lock` symlink, undermining serialization and lock authority. | Donor claimed resolved; pending U3a descriptor-safe lock proof. |
| 18 | C5136720627 / Finding ledger / Authority audit / 1 | `U3-I16` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | `historical_metadata_unavailable` | U3c | Live project identity was cached instead of being resolved and verified at the authority boundary. | Donor claimed resolved; pending U3c live-binding proof. |
| 19 | C5136720627 / Finding ledger / Authority audit / 2 | `U3-I17` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | `historical_metadata_unavailable` | U3c | Installed generation and configuration authority were not independently validated. | Donor claimed resolved; pending U3c installed-candidate proof. |
| 20 | C5136720627 / Finding ledger / Authority audit / 3 | `U3-I18` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | `historical_metadata_unavailable` | U3a | Expected run bindings were derived from the receipt being verified, permitting self-attestation. | Donor claimed resolved; pending U3a independent-verifier-input proof. |
| 21 | C5136720627 / Finding ledger / Authority audit / 4 | `U3-I19` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | `historical_metadata_unavailable` | U3a | Stable coordinator states could return before applying the required report migration. | Donor claimed resolved; pending U3a all-state migration proof. |
| 22 | C5136720627 / Finding ledger / Authority audit / 5 | `U3-I20` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | `historical_metadata_unavailable` | U3a | Released v1 error-envelope reports could be stranded by the converter. | Donor claimed resolved; pending U3a complete-v1-shape proof. |
| 23 | C5136720627 / Finding ledger / Authority audit / 6 | `U3-I21` | `51b9b7e7f9bb782243a703174dfbeb1334041baa` | `historical_metadata_unavailable` | U3a | Unreferenced evidence bundles could accumulate without a bound. | Donor claimed resolved; pending U3a bounded-input/retention proof without recreating a general repository. |
| 24 | C5139610859 / Stable finding ledger / 2 | `U3-ARCH-001` | `e1026c9afc3482fa1e6b8795cb8cbcf30ee0bd42` | P1 | U3c | Candidate-writable custody sidecars can target unrelated same-UID processes and omit detached descendants. | Open at review; donor later claimed closure; pending U3c threat-model proof. |
| 25 | C5139610859 / Stable finding ledger / 3 | `U3-ARCH-002` | `e1026c9afc3482fa1e6b8795cb8cbcf30ee0bd42` | P1 | U3c | Candidate execution exposed host root, procfs, and writable workspace, while networked execution bypassed the sandbox. | Open at review; donor later claimed closure; pending U3c sandbox proof. |
| 26 | C5139610859 / Stable finding ledger / 4 | `U3-ARCH-003` | `e1026c9afc3482fa1e6b8795cb8cbcf30ee0bd42` | P1 | U3b | Descriptor, driver, and verifier lacked one complete both-module, full-fault successful public-path execution. | Open at review; donor later claimed closure; pending U3b deterministic matrix proof. |
| 27 | C5139610859 / Stable finding ledger / 6 | `U3-ARCH-004` | `e1026c9afc3482fa1e6b8795cb8cbcf30ee0bd42` | P1 | U3b | The gate referenced a committed literal scenario catalogue that did not exist; tests substituted fake readers and plans. | Open at review; donor later claimed closure; pending U3b catalogue/real-reader proof. |
| 28 | C5139610859 / Stable finding ledger / 1 | `U3-ARCH-005` | `e1026c9afc3482fa1e6b8795cb8cbcf30ee0bd42` | P1 | U3b | Candidate SHA supplied or exposed its own controls, making controller, oracle, and verifier authority circular. | Open at review; donor later claimed closure; pending U3b independent-control proof. |
| 29 | C5139610859 / Stable finding ledger / 5 | `U3-ARCH-006` | `e1026c9afc3482fa1e6b8795cb8cbcf30ee0bd42` | P1 | U3c | Required coverage accepted deterministic-only evidence while installed/OpenRouter execution and authorization retry lifecycle were incomplete. | Open at review; donor later claimed closure; pending U3c installed/live proof. |
| 30 | C5139656686 / Finding disposition / 1 | `historical_metadata_unavailable` | `historical_metadata_unavailable` | `historical_metadata_unavailable` | U3b | An inherited worker-release descriptor with an invalid file descriptor could fail open. | Donor claimed mutation-local resolution; pending U3b clean-head review; mint a successor ID only if re-observed. |
| 31 | C5141519827 / item 1 | `historical_metadata_unavailable` | `23c8f401ad45c2ba632d1a410f767318e5f1e94a` | P1 | U3c | Candidate-controlled directory enumeration allocated and sorted the whole directory before applying its cap. | Donor claimed resolution at `c289c3d…`; pending U3c bounded-custody proof. |
| 32 | C5141519827 / item 2 | `historical_metadata_unavailable` | `23c8f401ad45c2ba632d1a410f767318e5f1e94a` | P1 | U3b | Intermediate checkpoint event validation checked structure but not complete event semantics or recomputed identity. | Donor claimed resolution at `c289c3d…`; pending U3b semantic-validator proof. |
| 33 | C5141519827 / item 3 | `historical_metadata_unavailable` | `23c8f401ad45c2ba632d1a410f767318e5f1e94a` | P2 | U3c | Interrupted multi-file lane publication could leave partial immutable bytes that strand replay forever. | Donor claimed resolution at `c289c3d…`; pending U3c transactional-publication proof. |
| 34 | C5141519827 / item 4 | `historical_metadata_unavailable` | `23c8f401ad45c2ba632d1a410f767318e5f1e94a` | P2 | U3b | Terminal evidence collection mutated directories, locks, indexes, or modes in the state it claimed merely to observe. | Donor claimed resolution at `c289c3d…`; pending U3b pure-collector proof. |
| 35 | C5141519827 / item 5 | `historical_metadata_unavailable` | `23c8f401ad45c2ba632d1a410f767318e5f1e94a` | P2 | U3c | Process-controller exceptions could escape before bounded failed-generation evidence was recorded. | Donor claimed resolution at `c289c3d…`; pending U3c process-failure proof. |
| 36 | C5141519827 / item 6 | `historical_metadata_unavailable` | `23c8f401ad45c2ba632d1a410f767318e5f1e94a` | P2 | U3b | Local case-ID validators drifted from the descriptor's shared `SAFE_ID` schema. | Donor claimed resolution at `c289c3d…`; pending U3b validator-parity proof. |

## Subordinate verification gap

This is not a 37th owned observation.

| Source locator | Stable ID | Reviewed SHA | Severity | Owner | Invariant | Status |
|---|---|---|---|---|---|---|
| C5141877842 / independent current-filesystem review / only non-blocking gap | `historical_metadata_unavailable` | `c289c3dade22f18782ee6c8f855c26851069849c` | P2 admission priority; historical severity unavailable | U3c, subordinate to Architecture Review 03 item 5 | Process teardown proof lacked an explicit process-group assertion. | Donor says the assertion was added and passed; U3c must re-prove it under its clean-head custody threat model. |

## Numeric readback

`READBACK donor_pr=910 donor_head=7d14ebb72801706f3029c1ca437d9f2f43825efe owned_observations=36 subordinate_gaps=1 owners{U3a=15,U3b=7,U3c=11,operator=3,rejected-invalid=0} stable_ids=29 idless_source_locators=7 reviewed_sha{known=23,historical_metadata_unavailable=13} severity{known=29,historical_metadata_unavailable=7} duplicate_owners=0 unassigned=0`

## Admission gates

The accepted plan at SHA-256
`6f69fce6f660997ca341fe9a2f2eaa3b00c0d432cabbe58b3341930e4622a0`
already permits this finite donor transition through F6, R39, R41, and the U3a
admission wording without weakening R6 for newly observed successor findings.

The seven ID-less observations remain locator-identified prevention
obligations: four owned by U3b and three by U3c. If an independent successor
review re-observes one on an exact head, that live finding receives a fresh
successor-scoped ID and all R6 metadata. Historical metadata is never invented.

Production mutation remains forbidden until all of these exact-current-head
actions complete:

1. The tracked ledger digest, numeric readback, and projected U3a
   file/dependency/responsibility map are published and read back.
2. A1 approves the complete `15/7/11/3/0` ownership map.
3. An independent clean exact-head review evaluates U3a's 15 assigned
   invariants and accepts the bounded admission map.

No donor resolution SHA is successor proof. No absent subsystem is
`rejected-invalid`. No historical ID, SHA, severity, or lens may be invented.
