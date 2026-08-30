# Completed agent children no longer poison live review locks

**Problem:** A review fixer could exit normally while its parent runner stayed
alive to poll hosted CI. The task lock still named the now-dead child, so the
stale-agent healer interpreted the healthy parent as a wedged review and
terminated it with `reason=review_agent_died`.

**Action:** Child PID/start-time fields now represent only the currently owned
agent. Headless agents, native OpenCode runs, and shared tmux Claude sessions
compare-and-clear their exact recorded identity after confirmed completion or
session teardown. The lock generation and live parent remain intact, and an
older completion cannot erase a replacement child.

**Evidence:** Focused lock, headless-agent, OpenCode lifecycle, and shared tmux
tests pin exact-match cleanup, mismatch refusal, and the parent-lock payload
after normal child completion.
