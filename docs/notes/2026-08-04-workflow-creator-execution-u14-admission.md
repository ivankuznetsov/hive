# U14 workflow-creator execution admission

Status: admitted for implementation from `origin/main`
`7b71bfdabc0fa59ef47c5b62d9f3add4c600457c` after PR #943 merged.

U14 owns only the deterministic execution trust substrate. U15 continues to
own provider selection, credential exposure, model/workflow sequencing, and
translation of an authenticated run into a passing claim.

## Dependency direction

```text
U15 orchestration
  -> WorkflowCreatorExecution
       -> WorkflowCreatorInstallation
       -> WorkflowCreatorGateway
       -> WorkflowCreatorArchive
       -> WorkflowCreatorProcessSupervisor
            -> WorkflowCreatorCapture
       -> merged WorkflowCreatorEvidence / Bundle / Core
```

Every edge points toward a U14 collaborator or the merged creator boundary.
`proof.rb` remains a bundle attestor/consumer and is not a U14 runtime owner.

## Production budget

U14 is capped at eight production/config files and six runtime owners:

| Path | Owner |
| --- | --- |
| `packaging/live_agent_skills/workflow_creator_execution.rb` | one typed session and result composition |
| `packaging/live_agent_skills/workflow_creator_installation.rb` | exact candidate/OpenClaw installation closure |
| `packaging/live_agent_skills/workflow_creator_gateway.rb` | serialized fixed command transaction |
| `packaging/live_agent_skills/workflow_creator_archive.rb` | bounded regular-only archive admission |
| `packaging/live_agent_skills/workflow_creator_capture.rb` | capped, redacted stdout/stderr evidence |
| `packaging/live_agent_skills/workflow_creator_process_supervisor.rb` | containment, termination, reaping, and supervisor receipts |
| `packaging/release_candidate/artifacts.rb` | exact source-builder closure only; no new owner |
| `config/component-boundaries.yml` | one downward-only component row; no new owner |

Tests and documentation do not count as production owners. Crossing either the
18-production-file plan ceiling or this tighter eight-file projection requires
re-scoping before further implementation. More than six runtime owners always
requires re-scoping.

## Settled boundaries

- Process custody is Linux-only and fails closed elsewhere. Adding a separate
  macOS descendant-custody design is not part of U14.
- U14 computes and validates caller-supplied installed paths and lock/package
  bytes; it never chooses an OpenClaw version or provider. U15 owns selection
  and installation orchestration.
- The supervisor admits only the closed creator labels: the nine semantic Hive
  command positions plus the candidate and outer OpenClaw roots. Zero launches
  is `not_started`; each launched label requires one complete teardown receipt.
- U1b remains the only primary-receipt mutation owner. U14 writes only the three
  fixed support members named by the merged vocabulary and exposes no generic
  publisher, process runner, archive extractor, or cleanup API.
- Receipt paths/descriptors remain supervisor-private. IPC is sequence-bound to
  run, attempt, label, and command position. Coherent arbitrary same-UID host
  compromise remains outside the guarantee.
- Pre-existing cleanup destinations are refused. U14 removes only paths it
  created whose current device/inode identity still matches its ownership row.

## Forbidden scope

No edits to the merged Values/TextSafety/Core/Bundle/Evidence/receipt-publisher
semantics; no provider/model/workflow authority; no credential selection; no
authenticated run; no live-success translation; no workflow YAML change; no
compatibility reader; and no transplant from frozen PRs #906, #909, #920, or
#921. Those PRs supply tests and historical findings only.

## Implementation slices

1. Archive and installation custody, including canonical retained manifests.
2. Bounded capture and Linux process supervision, including hostile teardown.
3. Fixed audit gateway and typed execution/session composition.
4. Deterministic creator integration, source closure, component contract, wiki,
   one broad local checkpoint, one three-lens final-head review, and hosted CI.

The slices may be developed in path-disjoint worktrees, but the coordinator is
the only writer to the U14 integration branch.
