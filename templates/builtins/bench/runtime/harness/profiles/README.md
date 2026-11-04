# Slate profiles

The direct v1 slate uses `harness@model` profiles from `slate.rb`. Claude and
Codex use their configured OAuth files; Pi requires an explicit provider/model
route. This document describes `ruby harness/run_all.rb` and
`ruby harness/pipeline_run.rb` through `IsolationExec`.

| Cell | Harness | Route / credential policy | Min version |
|------|---------|---------------------------|-------------|
| `claude@opus-4.8` | Claude Code | Configured Claude OAuth file | 2.1.118 |
| `codex@gpt-5.5-xhigh` | Codex CLI | Configured Codex OAuth file | 0.125.0 |
| `pi@kimi-k2.7` | Pi | `openrouter/moonshotai/kimi-k2.7-code`; `OPENROUTER_API_KEY` | 0.70.2 |
| `pi@minimax-3` | Pi | Bare `minimax-3`: refuses before spawn | 0.70.2 |
| `pi@qwen-2.6-coder` | Pi | Bare `qwen-2.6-coder`: refuses before spawn | 0.70.2 |
| `pi@glm-5.2` | Pi | `openrouter/z-ai/glm-5.2`; `OPENROUTER_API_KEY` | 0.70.2 |

`harness/preflight.rb` checks binary availability, auth-file presence and CLI
version only. An OK is not a model-routing guarantee; preflight behavior and
exit status are unchanged. Earlier claims that preflight confirmed all six
routes were incorrect.

`PI_MODELS` in `harness/profiles/slate.rb` still contains both bare labels.
Until both entries are qualified to verified `openrouter/<id>` routes, every
default unfiltered `run_all.rb` pass parks those cells in `failed` and exits 2.
Verify each provider/model id before changing it; do not infer it from the
label. Future migration surfaces are `PI_MODELS` and this README. This fix
leaves Slate labels, default selection and existing exit handling unchanged.

The packaged `generate.md` → `harness/hive_run.rb` → `HiveDriver` v2 candidate
path is outside this declaration. Its `env_args`/`auth_mounts` credential
forwarding and `hive_stages.sh` materialization of in-container `auth.json`
remain byte-for-byte unchanged. See [credential isolation](../CREDENTIAL_ISOLATION.md)
for the direct wrapper contract, proofs, refresh and recovery.
