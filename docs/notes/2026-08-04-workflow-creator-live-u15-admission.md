# U15 live workflow-creator orchestration admission

Status: implemented and locally verified from `origin/main`
`e822e12036a2d8e5b24b99b9895808a729ca5d88` after PR #944 merged;
authenticated exact-head evidence remains authorization-gated.

U15 owns only installed/live orchestration. The merged Workflow Creator Values,
Core, Bundle/Evidence, and Execution components continue to own value import,
schema semantics, primary publication, deterministic command custody, process
containment, teardown, and support-bundle publication.

## Dependency direction

```text
live workflow and smoke adapter
  -> WorkflowCreatorRunner
       -> WorkflowCreatorExecution (U14)
       -> WorkflowCreatorEvidence (U1b)
       -> WorkflowCreator Core / Bundle (U1a1c/U1a2)
```

No edge points back from a merged creator component into provider, credential,
OpenClaw setup, or workflow policy.

## Exact base characterization

- The live creator smoke is 672 lines with 20 methods. Its credential-free
  baseline at seed 944 is 4 runs, 22 assertions, zero failures/errors, and one
  expected live skip. Direct stdlib Coverage reports 125/261 executable lines
  and 13/24 branches on that file.
- The live creator workflow job has eight steps, two read-only permissions, and
  four external actions; none of those four uses is full-SHA pinned on this
  base.
- The smoke currently owns provider credential selection, OpenClaw discovery
  and configuration, process launch/timeout, the controlled Hive fixture,
  evidence projection, and cleanup. A successful model loop is deliberately
  finalized as `u14_execution_custody_unavailable`, so current main cannot make
  a passing composed live claim.

## Implemented shape

- The smoke is now a 127-line adapter with one authenticated test and one
  expected default skip. Provider/setup/process/evidence policy moved into the
  three packaging-owned U15 files; the workflow only installs the committed
  closure and invokes that adapter.
- The committed dependency is `openclaw@2026.7.2-beta.7` on Node `22.23.1`.
  A clean exact-Node install reproduced 331 lock rows / 321 installed packages,
  four reviewed lifecycle-script rows with scripts disabled, and zero
  production audit findings.
- A credential-free installed probe used the real beta7 runtime and candidate
  gem, read back the SQLite approval policy, stopped before the model loop,
  retained typed `workspace_preparation_failed` evidence with
  `model_loop=not_started`, and removed the disposable workspace.

## Owned and excluded paths

U15 may add one packaging-owned runner and, only when separation remains
narrow, one provider/environment policy collaborator. It may add the exact
OpenClaw package lock/inventory, thin the creator smoke, edit only the live
creator workflow job and its focused contract tests, add one component row,
and update the required release/wiki documentation.

U15 did not edit `workflow_creator_values.rb`, `workflow_creator_text_safety.rb`,
`workflow_creator.rb`, either creator contract, or U14 archive, installation,
capture, supervisor, or execution ownership. Two exact integration repairs were
required: U1b gained fixed primary-replacement facade calls so U15 does not
bypass publication custody, and U14's owner-private shebang gateway changed
from mode `0600` to `0700` so OpenClaw can execute the already-public gateway
path. Neither repair adds policy or state ownership. U15 does not transplant
the frozen PR #906 subsystem or add a generic provider, process, archive,
installation, configuration, evidence, or recovery framework.

## Runtime owners and integration acceptance

The production shape remains three responsibilities: exact candidate/OpenClaw
setup and workspace policy, provider/transport orchestration, and bounded
installed-runtime sealing. Tests and workflow adapters add no production owner.

`U15-INT01` re-proves, without co-owning or reopening, the already closed
`F01` evidence-identity and `F03` installation/teardown invariants. The final
passing primary must be published through U1b, validated through the merged
Core and Bundle contracts, and completed through U14 on the exact authored and
executed instruction plus retained candidate/OpenClaw closures.

## Required behavior

- Persist the schema-valid `preflight/not_started` receipt before any model,
  credential, binary, dependency, or artifact preflight; replace it with one
  typed non-passing result on every ordinary failure.
- Derive `openai` or `openrouter` solely from the configured model prefix and
  expose exactly that provider's credential only to the outer OpenClaw child.
- Remove provider, GitHub, Git helper/config, SSH, and generic agent authority
  from model-invoked tool and candidate environments. Bind approved endpoint,
  proxy, and CA inputs and reject unapproved overrides before credential use.
- Admit and invoke the committed exact OpenClaw package/version/registry/
  integrity closure and native executable path. The workflow installs that
  lock; it does not select a floating package.
- Compose the two exact outer prompts, authored instruction, U14 draft, U1b
  primary publication, and U14 finish/cleanup without a compatibility reader
  or synthetic success fields.
- Keep the smoke responsible only for live availability and result assertions;
  keep the workflow responsible only for immutable setup and artifact upload.

## Verification and authority fence

Run focused runner, smoke, workflow-contract, component-boundary, operating
skill, and release-contract tests during implementation. Run one broad
`bundle exec rake test` checkpoint on the final local head, then one parallel
three-lens review and one hosted exact-head CI cycle.

The final focused checkpoint before broad testing is 137 runs / 1,994
assertions / zero failures / zero errors / one expected live skip. Hostile
property campaigns remain optional and outside normal CI.

An authenticated provider run is not authorized by implementation work. It
requires fresh operator authorization bound to the unchanged exact head after
credential-free proof, terminal CI, and the independent security review. A
head change voids that authorization. Merge authority does not authorize a tag,
release, package publication, or deployment.
