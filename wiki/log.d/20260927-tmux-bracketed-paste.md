# 2026-09-27 — Interactive prompts are pasted as one bracketed paste

- `TmuxRunner#send_prompt` pasted prompts with `paste-buffer -d -r` and no
  `-p`, so tmux delivered a large buffer as many unbracketed chunks. Current
  Claude Code turned each chunk into its own `[Pasted text #N]` and a short
  trailing chunk into typed text. A hivedev execute stage received only the
  prompt's last two lines (the context-provenance appendix tail) twice, asked
  what to do, and exited without changes (`execute_waiting`).
- The paste now uses `-p`, which brackets the buffer when the agent enabled
  bracketed paste (Claude Code does): the whole prompt arrives as a single
  `[Pasted text #1 +N lines]`. Verified directly against Claude Code with a
  250 KB prompt (unbracketed: 28 fragments; bracketed: one paste).
