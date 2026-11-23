## 2026-11-22 — Process-custody scan skips zombies instead of aborting

- Symptom: every OpenCode role (live: the `opencode/gemini-4-neon` plan-review
  adversary on uk-new-companies 43470) died about a second after spawn. Its
  stage log stopped after the spawn and MCP notice lines, and the route
  recorded `terminal_failure` with an empty diagnostic, which read like a
  model failure.
- Cause: `InvocationProcessCustody#procfs_matches` reads every same-uid
  `/proc/<pid>/environ`. A zombie (four `codex <defunct>` children of the Codex
  app-server on hivebox) has no address space, so the read raises
  `Errno::ESRCH`. That was not in the per-entry rescue, so it escaped
  `after_exit` before `write_capture_log` ran, which discarded OpenCode's own
  output (an expired OpenCode key was hidden behind it). The `ensure` cleanup
  then re-raised it.
- Change: per-entry `rescue Errno::ESRCH` treats the row as a non-match. A
  zombie or a process mid-exit is already dead and cannot carry a live
  custody ID.
- Tests: `test/unit/invocation_process_custody_test.rb` now spawns a real
  unreaped child and runs the real `/proc` inventory, plus a fake-procfs ESRCH
  case. Before the fix, the existing real-procfs cleanup test also failed on
  any host with a zombie.
- Pages: [[modules/agent_profile]].
