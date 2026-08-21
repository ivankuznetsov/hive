# Shared Claude reviewer sessions accept the common scope shape

Mixed 6-review rosters could finish their non-Claude reviewers and then crash
before opening the following shared Claude tmux session. The review runner
passes `Base.tool_scope_kwargs(scope)` to every launcher, but
`ClaudeLauncher.with_shared_session` did not accept the three OpenCode-only
keywords in that stable shape, even when all three values were empty.

The shared-session boundary now accepts empty OpenCode roots and edit patterns
and rejects non-empty values because the session is Claude-only. Regression
coverage exercises both the normal empty shape and the fail-closed branch.
