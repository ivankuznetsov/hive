## 2026-06-11 — claude.model / claude.effort: hive stops inheriting the operator's interactive model

hive-launched claude sessions now pass `--model` (and optionally
`--effort`). The default `claude.model: default` uses Claude Code's live
"default" alias — tracking ITS recommended model (Opus-class today)
without hardcoding a name — instead of inheriting whatever the operator
last picked interactively (dogfooding found pipeline runs silently
billing Fable). `inherit` restores the old behavior; any alias/full name
passes through (`sonnet` = budget pick). `claude.effort` defaults to
Claude Code's own tier (high today) by omitting the flag; low/medium/high
pass through. Selected during `hive init`: new TTY prompts and the
non-TTY defaults add two answer slots after permission mode, and the
`hive-init.v1` `answers` object carries required `claude_model` /
`claude_effort` keys. Flags ride `Hive::Config.claude_cli_flags` into the
tmux wrapper and the headless Agent argv. This cherry-pick is gem-side
only; branch-side web questionnaire and task-page changes are not present
in this checkout. See [[modules/config]], [[commands/init]], and
[[modules/agent]].
