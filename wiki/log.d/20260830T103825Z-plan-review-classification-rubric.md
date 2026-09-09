# 2026-08-30 — Plan-review classification rubric

Primary and adversarial plan-review prompts now define `safe_auto`,
`gated_auto`, `manual`, and `fyi` by decision authority. Routine technical
corrections with a repository-grounded disposition no longer become manual
operator questions merely because the plan must make a choice; manual is
reserved for consequential choices that the existing contract cannot safely
determine. The Hive prompt rubric is authoritative for the final JSON even when
an invoked review skill has a different internal routing rubric.
