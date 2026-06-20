## [2026-06-20T07:28:12Z] reviewers — normalize codex native `[Pn]` review output

**Action:** Fixed a recurring patrol `6-review` `reviewers/all_failed` regression
where `codex-native-review` rejected real findings because codex-cli (0.141.0)
ignored the prompt's `## High/Medium/Nit` GFM coercion and emitted its native
`codex review` format instead — a "No plan was found" preamble plus `[P1]/[P2]`
priority bullets. The parser's `SEVERITY_HEADER` check found no headers, failed,
and retried the same deterministic failure until the stage exited `all_failed`;
because patrol's only reviewer is `codex-native-review`, every patrol PR looped
on a full xhigh review (~7–10 min/pass) without ever advancing.

`lib/hive/reviewers/codex_review.rb` now classifies an answer carrying ≥1 native
`[Pn]` bullet (and no `## High/Medium/Nit` header) as `:findings`, and
`findings_markdown` normalizes it via `normalize_native_findings`: each
`- [P1] …` bullet becomes a `## High/Medium/Nit` checkbox (P1→High, P2→Medium,
P3+→Nit, per `NATIVE_SEVERITY`), the finding's indented justification is folded
onto its single line, repeated echoes are de-duplicated, and empty severities
still print their header + `No findings.` so triage's `- [ ]` parser consumes
the result. The GFM-findings, clean-verdict, template-echo, and error paths are
unchanged; a prose-described finding with no `[Pn]` tag still fails (not laundered
into a clean pass).

Distinct from the #512 fix (review timeouts/caps + the prompt-echo `all_failed`):
this is a codex-CLI output-format drift that retries could never resolve. Added
`test_native_priority_findings_are_normalized_to_gfm` and
`test_native_findings_are_deduplicated`.

**Refreshed pages:**
- [[modules/reviewers]]
