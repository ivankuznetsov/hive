## 2026-11-08 — Fix guardrail scans only fix-introduced content

- `FixGuardrail.run!` now intersects its `base..head` matches with the task
  branch's own diff against the review compare ref
  (`merge-base(<default_branch>, head)..head`), so a non-ancestor base no
  longer reports its own changes reversed and a merge of the upstream default
  branch no longer reports upstream workflows, fixtures, and deletions.
- Fallback to the unfiltered scan when the compare ref is unset or
  unresolvable, histories are unrelated, or head is reachable from upstream;
  git failures still raise.
- Regressions in `test/unit/stages/review/fix_guardrail_test.rb` cover the
  non-ancestor base, the upstream merge, a fix that trips after a merge, the
  unresolvable-ref fallback, and a failing task-scope diff.
- Hive task: fix-guardrail-flags-changes-that-261108-07b6.
