---
date: 2026-06-18
slug: fix-agent-generalize-defect-class
pages: [stages/review]
---

Nudged the 6-review fix agent to fix the whole defect class, not just the cited
line. `templates/fix_prompt.md.erb` previously said "do NOT refactor adjacent
code" full stop, so the fix agent patched only the one site a finding cited;
the next reviewer pass then re-found the identical bug at the next site,
burning a full extra pass per site. Real case that motivated this: an
xhigh-effort review of an xbookmark browser-source PR found the same
silent-truncation / session-expiry-swallowed class across `walk_timeline`,
`get_tweet`, capture, and resync over five separate passes, one site per pass.

Added a bounded carve-out (new step 3 in the fix prompt's "What to do"): when a
finding's root cause is an instance of a recurring pattern, grep the worktree
for the other sites with the SAME defect and apply the identical remedy to all
of them in this pass, naming the extra sites in the final message. Explicitly
scoped: it is the one exception to scoped-edits and is NOT license for unrelated
refactors/renames/improvements. ERB renders unchanged (prose-only, no new
binding); `prompt_injection_test.rb` (13) still green. Updated [[stages/review]]
Phase 4. Shipped on the same branch as the triage-retry / error-surfacing work
(PR #512).
