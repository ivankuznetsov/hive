# Preserve approved verification pass admission on restart

`Review.admitted_pass_ceiling` now recognizes controller-written `kind=approved`
receipts alongside legacy CI-repair receipts. Each admits exactly one further
verify-only reviewer pass, allowing final-verification guardrail approval to
survive interruption, findings, and reviewer errors without extending the repair
budget. The in-memory loop also honors that ceiling when approval happened before
triage and no escalations file exists for the approved pass. Regression coverage
exercises approval and retry after all three outcomes, receipt chains, and
rejection of reviewer files beyond the admitted ceiling.

Updated [[stages/review]].
