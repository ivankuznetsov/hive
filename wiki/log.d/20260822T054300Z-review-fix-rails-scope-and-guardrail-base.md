# 2026-08-22 — review fix Rails source scope and recovery guardrail base

**Action:** A live Pi review-fix pass repaired findings in Rails routes,
initializers, production configuration, CI orchestration, a migration, and the
schema, then Hive rejected its fallback commit because the default static scope
denied all `config/**` and omitted `db/**`.

The default scope now treats top-level framework `config/**` and `db/**` as
ordinary product source. Rails `config/master.key` and
`config/credentials/**` remain explicitly denied, as do CI workflows,
dotenv/secrets, executable paths, and dependency lockfiles. Exact staged-object
secret and mode checks plus the post-fix diff guardrail remain in force.

The retry path also captures the guardrail base before `CleanExit` checkpoints
pre-existing residue. Previously a scope failure could leave edits dirty, the
daemon could retry, and the pre-fix snapshot would fall outside the subsequent
guardrail diff. Recovery now scans the complete repair, including that snapshot.

That recovered checkpoint exposed a second split boundary: exact
`review.fix.guardrail.waivers` released a secret-pattern match only in the
post-fix diff guardrail, while `CleanExit` rejected the same fingerprint before
it could be checkpointed. Both gates now use one strict waiver parser and one
exact `(pattern, SHA-256)` set. No value/path allowlist was restored; an
unwaived test password or any changed fingerprint still fails closed.

**Verification:** Focused scope tests pin all six paths from the live failure as
accepted and keep Rails credential paths denied. An integration regression puts
a shell-pipe finding in pre-fix residue and proves the recovered review pauses on
`fix_guardrail` after the residue is checkpointed. A CleanExit regression proves
an exact waiver releases the matching staged fixture while the existing
unwaived and changed-value cases remain blocked.
