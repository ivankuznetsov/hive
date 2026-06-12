## 2026-06-11 — claude.model / claude.effort: hive stops inheriting the operator's interactive model

hive-launched claude sessions now pass `--model` (and optionally
`--effort`). The default `claude.model: default` uses Claude Code's live
"default" alias — tracking ITS recommended model (Opus-class today)
without hardcoding a name — instead of inheriting whatever the operator
last picked interactively (dogfooding found pipeline runs silently
billing Fable). `inherit` restores the old behavior; any alias/full name
passes through (`sonnet` = budget pick). `claude.effort` defaults to
Claude Code's own tier (high today) by omitting the flag; low/medium/high
pass through. Selected during init on BOTH surfaces: new TTY prompts
(scripted-answer order gains two slots after permission mode) and the web
setup questionnaire. Flags ride `Hive::Config.claude_cli_flags` into the
tmux wrapper and the headless Agent argv. The task page's Reject/Force
approve moved into a described Advanced section at the page bottom.
See [[modules/config]], [[commands/init]], [[commands/web]].
