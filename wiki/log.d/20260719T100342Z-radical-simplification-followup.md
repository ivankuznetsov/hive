# Radical simplification follow-up

- Derived ready-action command routing from `TaskAction::ACTIONS` so the bot
  and web no longer maintain independent command maps.
- Kept web dispatch narrower by projecting the shared map through the daemon
  queue allowlist; `ready_to_advance` remains an in-process approve action.
- Closed the corresponding Hivebox residual in `wiki/gaps.md`.
