## Outcome-evidence review can return repository defects to execute

**Problem:** The independent artifacts reviewer could accept proof, request
replacement proof, or block. A finding that required source, configuration,
tests, or repository documentation therefore became an operator-owned blocker,
even though a same-stage evidence recovery could not change the frozen
implementation.

**Action:** Added the closed `rework` reviewer verdict and a digest-bound,
controller-only `hive evidence rework` transition from `7-artifacts` to
`4-execute`. Hive keeps the rejected generation immutable, appends at most two
authorization receipts, protects its documents, representations, provider
manifests, and complete receipt namespace, and injects the exact reviewer
targets and reasons into the implementation prompt.
Future receipt slots are protected before the first receipt exists, unknown
siblings cannot poison inventory reads, and every contract-valid reviewer
payload fits the shared 256 KiB document ceiling. An unchanged implementation
tree, including an empty descendant commit, cannot complete execute or loop
back through fresh evidence. A third reviewed implementation return becomes the explicit
operator-owned `reworks_exhausted` blocker. Daemon queue admission accepts only
the exact command shape under a distinct `outcome_evidence_rework` action and
does not require a provider route until execute actually launches a model. Web,
Telegram, and OperationalAction route that same exact command instead of
synthesizing a familiar stage verb.

**Verification:** Added contract, store, receipt, command, action, queue,
dispatcher, healer, artifacts-stage, execute-stage, schema, and prompt coverage,
including stale bindings, append-only/idempotent receipts, providerless
controller dispatch, cross-surface action parity, reviewer feedback propagation,
mixed revise/rework history, empty-commit refusal, protected empty receipt
slots, maximal feedback, non-receipt sibling tolerance, and bounded exhaustion.
