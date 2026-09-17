# security-lint-ci-for-package-260709-dcee — Brainstorm

Security lint CI that gates honeycomb submissions: fork-safe, label-gated
GitHub Actions running the package validator, a SECRET/PII scan, and
instruction static analysis whose output is evidence for a human reviewer.
A honeycomb stays UNLISTABLE until the lint passes AND a human approves.

## Round 1

### Q1. Stack & reuse boundary.
The idea references hive-bench's `validate-submission.yml` and
`validator/secret_scan.rb` (Ruby). Should this CI be implemented in the same
stack — Ruby scripts invoked from GitHub Actions, porting hive-bench's pattern
sets directly — or reimplemented in another language (shell/JS)? And does the
"package validator" from task 1848 already exist as a script this CI can shell
out to, or must this task treat it as a contract/stub to call?
### A1.
Use Ruby scripts invoked by GitHub Actions and port the relevant hive-bench
scanner patterns with attribution and tests. Treat task 1848's commands and
JSON schema as the contract; this task may provide a temporary fixture adapter
for isolated tests, but must not fork or reimplement the validator.

### Q2. Pass/fail semantics.
Which checks are HARD failures that block the lint versus ADVISORY evidence
that is surfaced but does not fail CI? Specifically: validator errors and
SECRET/PII hits presumably hard-fail — but do deny-pattern hits
(curl|bash pipes, credential-path reads, base64 exfil shapes, non-allowlisted
network calls) fail the check, or only get annotated for the reviewer to weigh?
### A2.
Hard-fail on schema/integrity errors, secrets or high-confidence PII, path
traversal, credential-path reads, pipe-to-shell/download-and-execute patterns,
encoded-exfiltration patterns, undeclared network hosts, and permissions that
exceed the manifest. Ordinary extracted commands, declared hosts, broad but
declared permissions, and lower-confidence heuristic hits are advisory evidence
for the human reviewer. A narrowly justified, maintainer-approved suppression
may downgrade a hard pattern; it must never silently hide the evidence.

### Q3. "Instruction files" scope & extraction.
Which paths under `packages/**` (or the honeycomb dir) count as instruction
files for static analysis — the `workflow.yml` descriptor, stage-instruction
markdown, all files, or a defined glob? How should shell-command extraction be
scoped (fenced code blocks, inline backtick commands, both)? And how are the
descriptor's requested permissions located (a known manifest field vs
heuristics)?
### A3.
Secret/PII scan every text file in the changed package version. Instruction
analysis covers `workflow.yml`, `instructions/**/*.{md,txt,yml,yaml}`, and
package `README.md`; extract fenced blocks, inline backticks that parse as
commands, and YAML string values. Requested permissions come from the known
workflow descriptor fields and are compared with the generated manifest; use
heuristics only to find suspicious undeclared behavior, not to invent the
authoritative permission declaration.

### Q4. Allowlist & suppression sources.
Where does the network-host allowlist live — a checked-in file in this repo, a
per-honeycomb manifest field, or both — and who maintains it? Same question for
any known false-positive suppressions for the secret/PII scan (e.g. example
tokens in docs). Should these be honeycomb-declared and reviewer-approved, or
repo-global only?
### A4.
Keep a small repo-global baseline allowlist under `policy/` for stable service
hosts and scanner fixture fingerprints. Package-specific hosts and suppressions
live in the package manifest with a mandatory reason and are effective only
after human approval. Maintainers own both sources. Never allow arbitrary regex
suppression of secret findings; allow exact test-fixture fingerprints or
documented placeholders so a suppression cannot mask a later real token.

### Q5. Fork-safety & re-validation lifecycle.
Confirm the trigger model: `pull_request` (not `pull_request_target`),
`contents: read`, no secrets, gated by a maintainer applying `safe-to-validate`.
When new commits land after the label is applied, must the label auto-clear and
be re-applied before the lint re-runs? Should a prior passing lint verdict /
approval be invalidated on any new push, so review can't be bypassed by
"approve clean, then push malicious"?
### A5.
Confirmed: use `pull_request`, never `pull_request_target`, with no secrets and
read-only contents for code-scanning jobs. A maintainer applies
`safe-to-validate` to a specific head SHA. Any `synchronize` event invalidates
the lint result and human approval, removes or logically expires the label, and
requires re-application. The check and approval record must include the exact
head SHA so catalog generation cannot accept a stale verdict.

### Q6. Listing-gate scope boundary.
"UNLISTABLE until lint passes AND human approves" spans catalog generation
(task 1848) and the trust model (task 1850). For THIS task, is the deliverable
only the CI checks + PR evidence comment + a machine-readable pass/fail status
(e.g. a required status check / label)? Or does it also own the enforcement
mechanism that keeps unapproved honeycombs out of `catalog.json` (e.g. a
`listed`/`reviewed` gate)?
### A6.
Own the lint workflows, sticky evidence comment, machine-readable artifact, and
SHA-bound pass status. Also provide the approval-record shape consumed by task
1848, but keep catalog filtering/generation in 1848 and policy prose in 1850.
The integration test must prove that a package without both current-SHA lint
and approval records is absent from generated catalog output.

### Q7. Evidence output format & UX.
Should the reviewer evidence be a single sticky PR comment updated in place per
run, with structured sections (extracted shell commands / requested permissions
/ deny-pattern hits / secret-PII findings)? Should it also emit a job-summary
and/or a machine-readable artifact for downstream tooling? Confirm user-facing
copy uses the "honeycomb" term per the 2026-07-09 naming decision.
### A7.
Publish one sticky PR comment updated in place, a matching job summary, and a
versioned JSON artifact. Sections: package/version and head SHA, validator,
requested permissions, extracted commands, network hosts, deny-pattern hits,
secret/PII findings, suppressions, and final lint verdict. Use “honeycomb” in
all user-facing copy; reserve “package” for paths and implementation details.

### Q8. Definition of done & non-goals.
What acceptance cases prove this works — e.g. a crafted malicious honeycomb PR
is caught and annotated, a clean one passes, and a fork PR runs safely without
secret exposure? And confirm the non-goals: no semantic/LLM-based prompt-
injection detection (the lint surfaces evidence, humans judge intent), no
auto-merge / auto-list, and no sandboxed execution of instruction prompts in
this task.
### A8.
Acceptance requires fixtures proving: a clean honeycomb passes; malformed or
tampered manifests fail; malicious command, secret, PII, undeclared-host, and
permission-escalation cases fail and are annotated; advisory evidence remains
visible without failing; fork PRs receive no secrets or write token; and a new
push invalidates prior lint/approval. Confirmed non-goals: no LLM/semantic
intent classifier, auto-merge, auto-listing, or execution/sandboxing of
submitted instructions.

<!-- COMPLETE -->
