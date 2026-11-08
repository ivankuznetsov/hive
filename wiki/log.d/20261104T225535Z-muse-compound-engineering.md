# 2026-11-04 — Compound Engineering provisioning for Muse

**Action:** Muse refuses to install any plugin bundle containing symlinks
(`plugin contains symlink entries and cannot be installed`), and upstream
Compound Engineering ships several, which is why the earlier Muse profile
left CE operator-installed. Hive now provisions it properly:
`Hive::AgentSupport::Muse::PluginStaging` clones the manifest git source
into `<muse data home>/hive/compound-engineering/`, copies it dereferencing
every symlink (`.git` excluded, cycles fail closed), verifies no symlinks
remain, and the setup adapter installs or updates the native plugin from
that staged tree (`muse plugins install`/`update`/`enable`). The staged
tree stays the plugin's recorded source, so updates re-stage before
`muse plugins update` re-reads it; a plugin installed from any other path
is an ownership conflict Hive will not replace. `config/agent-skills.yml`
gained the muse CE package and all five CE capability rows, the skill
verifier resolves CE skills from `plugins/installed.json` cache paths,
live/filesystem inventories read Muse's plugin registry (environment now
plumbs through `FilesystemInventory` because plugin state lives in the XDG
data home), the plan stage maps Muse to `/ce-plan`, and init offers
`muse-ce-code-review` as an opt-in reviewer. No default agent selection
changed.

**Verification:** `test/unit/agent_skills/muse_ce_test.rb` covers real-git
staging with dereferencing, adapter install/update/enable/foreign-conflict
plans, registry inventories, plugin-cache skill resolution, and a hermetic
inspect → stage → install → healthy provisioner cycle through the extended
`test/fixtures/fake-muse` (which mirrors the real symlink refusal). Live
proof in a fake home with the real muse binary and real upstream clone:
plan `[plugin_stage, plugin_install]` staged v3.35.3, all three inspected CE
rows reached healthy, a second plan was empty, `muse skills list` shows all
35 CE skills, and the doctor filesystem-inventory path reports healthy.

**Wiki:** Updated [[modules/agent_profile]], [[commands/setup-agents]],
[[gaps]]; docs/architecture.md CE note revised.
