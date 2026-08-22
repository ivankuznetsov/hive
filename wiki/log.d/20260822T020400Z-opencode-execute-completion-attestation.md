# OpenCode execute recovery distinguishes checkpoints from completion

The Webmail.sh provider dogfood showed that Ox Alpha can return an empty
terminal assistant message after many productive tool steps. It also showed
that a clean descendant commit alone is not completion evidence: the resumed
agent committed U1 as a durable checkpoint and continued implementing the
remaining units. Treating that commit as terminal would have advanced an
incomplete plan if the provider had stopped at that boundary.

Execute prompts now reserve a plan-bound `Hive-Execute-Complete: <SHA-256>`
commit trailer for the final commit only. OpenCode's narrow exit-zero malformed
output recovery requires that exact trailer in addition to the existing clean
worktree, expected branch, new descendant commit, and zero-exit checks.
Intermediate commits remain durable retry checkpoints but can never authorize
stage completion. Commit-message inspection accepts only an exact object ID,
so an agent-controlled revision expression cannot alter the controller's Git
query.
