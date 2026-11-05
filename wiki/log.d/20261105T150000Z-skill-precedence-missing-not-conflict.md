# 2026-11-05 — Lower-precedence foreign skill is "missing", not "conflicting"

**Action:** `Hive::AgentSkills::Inspector#inspect_bundled_resolution` reported
`conflicting` whenever the operating skill resolved anywhere other than the
managed destination, even when that destination was simply not installed yet
and outranks the winner in the provider's own candidate order. Muse reads
`~/.claude/skills`, so any operator with Claude's `/hive` projection got a
permanent refusal and Muse never received its own copy. The inspector now
reports `missing` (and plans the publish) when the managed destination comes
first in `resolved.candidates`; a genuinely higher-precedence shadow (for
example project `.agents/skills/hive`) is still `conflicting`.

**Verification:** `test/unit/agent_skills/` passes; a read-only inspection on
a real home with `~/.claude/skills/hive` plans one `bundled_skill_publish` to
`~/.config/muse/skills/hive`.
