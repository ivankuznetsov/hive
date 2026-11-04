# Slate profiles

The v1 benchmark slate is six `harness@model` cells. hive (the source project)
pins a model only for `claude` — `Hive::Agent#build_cmd` rejects model flags for
`codex`/`pi` — so hive-bench carries its own `Profile` layer (`harness/lib/profile.rb`)
that bakes the model flag into each cell's headless invocation.

| Cell | Harness | Model pinning | Min version |
|------|---------|---------------|-------------|
| `claude@opus-4.8` | Claude Code | `claude -p --model opus-4.8` | 2.1.118 |
| `codex@gpt-5.5-xhigh` | Codex CLI | `codex exec -m gpt-5.5 -c model_reasoning_effort="xhigh"` | 0.125.0 |
| `pi@kimi-k2.7` | Pi | `pi -p --model kimi-k2.7` | 0.70.2 |
| `pi@minimax-3` | Pi | `pi -p --model minimax-3` | 0.70.2 |
| `pi@qwen-2.6-coder` | Pi | `pi -p --model qwen-2.6-coder` | 0.70.2 |
| `pi@glm-5.2` | Pi | `pi -p --model glm-5.2` | 0.70.2 |

## Open-model feasibility — resolved

The origin flagged "can Pi actually run the four open models?" as the one open
risk. **Yes:** `pi --model <pattern>` exists (Pi v0.79.3, "supports provider/id
and optional `:<thinking>`"), and `ruby harness/preflight.rb` confirms all six
cells resolve (binary + auth + version) on the maintainer's machine. The exact
Pi provider/id pattern per open model depends on the local Pi provider config
(OpenRouter); if a smoke run reports an unresolved pattern, adjust `PI_MODELS`
in `slate.rb`.

`harness/preflight.rb` is the live check — run it before any benchmark pass.
