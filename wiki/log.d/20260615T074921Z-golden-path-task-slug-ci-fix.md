# golden-path E2E task slug CI fix

After rebasing PR #479, GitHub Actions failed `hivebox web (Rails tests + system)`
in `web/test/e2e/golden_path_e2e.rb` with:

`NameError: undefined local variable or method 'task_slug'`

The failing line came from the recent golden-path E2E stabilization that added
`task_slug_from_grid!` but then called an undefined `task_slug` local after
navigating to the task page. The documented intent in [[testing]] is to read the
slug from one current-DOM grid query before navigation, then use that stable
slug for the daemon answer-window wait. Updated the test to store
`task_slug = task_slug_from_grid!("Golden path sample idea")` before clicking
the row and pass that value to `wait_for_answer_window!`.

No new wiki page or index update was needed; [[testing]] already describes this
pattern.

**Refreshed pages:**
- [[testing]]
