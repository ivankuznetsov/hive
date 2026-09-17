# Reviewer prompts use merge-base diff range

Patrol finding `architecture-templates-part-8-20260917T000739Z-a272c010-1`
(generation 1): the agent reviewer templates (`reviewer_grok_ce_code_review`,
`reviewer_pr_review_toolkit`, plus the sibling `reviewer_claude_ce_code_review`,
`reviewer_codex_ce_code_review`, and legacy `review_prompt`) instructed
reviewers to run `git diff <default_branch>..HEAD` — the two-dot tip-to-tip
range. When the default branch advanced after the feature branch was cut, that
range also emitted the inverse of the new default-branch commits, so reviewers
saw unrelated "changes" the branch never introduced. The codex native reviewer
already used the three-dot merge-base range (`...`) and was correct.

All five affected templates now render `git diff <default_branch>...HEAD`, so
every reviewer sees only the changes the branch itself added.
`test/unit/templates/reviewer_diff_range_test.rb` pins the merge-base notation
across all reviewer templates, and the
`Reviewers::Agent` argv test now asserts `git diff main...HEAD`.
