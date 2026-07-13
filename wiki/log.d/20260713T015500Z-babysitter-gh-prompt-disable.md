# 2026-07-13 — disable prompts for babysitter dry-run gh reads

Allowlisted `gh` reads now force `GH_PROMPT_DISABLED=1` before handing off to
the real binary. This keeps identifier-less `gh run view` and
`gh workflow view` from opening interactive selectors under the babysitter PTY
and consuming the enclosing agent timeout. A prompt-sensitive PTY regression
covers both bare forms while proving they still reach the real binary.

Pages: [[commands/babysit]], [[modules/babysitter]], [[testing]].
