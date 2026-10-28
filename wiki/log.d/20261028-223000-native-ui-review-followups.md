# Native UI review follow-ups (Astra A1, A6)

Split diff panes scroll in sync again: overflow moved back to the
`.d2h-file-side-diff` elements diff2html synchronises (an inner
`.d2h-code-wrapper` scroller had broken it). Empty `## Implementation`
suppression moved into `render_markdown`, so the Documents list matches the
primary document. Push `not_observed` (local tracking ref absent) is omitted
instead of claimed as "Not pushed". Tasks with a PR but no worktree link the
PR's files on GitHub. See commands/web.md "Document and diff presentation".
