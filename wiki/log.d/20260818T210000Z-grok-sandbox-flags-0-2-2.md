# agent-cli-runtime 0.2.2 — Grok declares its sandbox flags

`AgentCliRuntime::Profiles::GROK` now declares `workspace_write_flags` and
`read_only_flags`, mapping to Grok's built-in `--sandbox workspace` and
`--sandbox read-only` profiles plus `--always-approve`. Only the Grok profile
changes.

## Why it mattered

`Profile#workspace_write_supported?` is `!workspace_write_flags.empty?`.
Measured honestly, that was **false for claude, pi and grok alike** — only
codex declared real flags. Hive's plan review therefore gated reviewers on:

```ruby
profile.workspace_write_supported? || %i[claude pi].include?(profile.name)
```

so claude and pi qualified purely because their names were typed into that
array, and grok was refused with a message that read like a capability finding:

```
provider cannot enforce disposable workspace confinement
```

Grok in fact confines the filesystem natively, the same shape codex uses, and
its permission surface (`--allow`, `--deny`, `--disallowed-tools`,
`--permission-mode`, `--sandbox`) is at least as expressive as claude's.

## Verified

Both sandbox profiles accept real runs, and a review under
`--sandbox workspace --always-approve` read a read-only 33KB plan, wrote only
its verdict file, and shelled out to compute SHA-256 successfully.

## Release path

The gem is canonical in this monorepo at `components/agent-cli-runtime`;
`ivankuznetsov/agent-cli-runtime` is a **distribution mirror** synced from Hive
main on a schedule (`mirror/sync-from-hive.yml`), so the change lands here, not
by a pull request against the mirror. Version bumped 0.2.1 → 0.2.2 with the
`~> 0.2.0` constraint unmoved, since the change is additive to one profile.

Note for anyone dogfooding: installed Hive loads this gem from
`~/.local/share/gem/.../agent-cli-runtime-<version>/`, **not** from
`components/`, so an unreleased component edit has no runtime effect until the
gem is rebuilt.

See [[dependencies]], [[modules/plan-review]].
