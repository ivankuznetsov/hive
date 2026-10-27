# 2026-10-27 — Evidence closure confirms with y/N or --yes

- `hive archive TARGET --reason … --evidence …` no longer asks the operator to
  type `CLOSE <digest-prefix>`. After the evidence preview passes it asks
  `Archive <slug> as <reason>? [y/N]`, and `--yes` confirms without a prompt or
  terminal, so scripts and agents can close tasks whose delivery GitHub
  verifies. Evidence verification and the re-check before `closure.json` are
  unchanged. See [[commands/stage_action]].
