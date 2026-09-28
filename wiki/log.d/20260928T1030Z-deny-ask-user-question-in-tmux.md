# 2026-09-28 — tmux Claude launches deny AskUserQuestion

- A yolo `4-execute` Claude session in tmux mode called `AskUserQuestion` and
  sat on the question menu for about two hours. Tmux stage sessions are
  detached and finish only through the Stop hook, so nobody answers the menu
  and the stage waits until its timeout.
- `wrapper_command` now always appends `AskUserQuestion` to
  `--disallowedTools`, whatever the permission scope (yolo included). The deny
  is deduplicated when a scope or runtime policy already lists it. Headless
  `claude -p` launches are unchanged.
