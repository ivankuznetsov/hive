## [2026-08-25T17:51:00Z] bench — classify Claude CLI stdout quota banner

**Action:** Claude CLI 2.1.233 emits its subscription-limit reset banner on
stdout with exit 1, while the benchmark judge adapter previously inspected
only stderr for typed provider-limit evidence. The adapter now accepts the
exact standalone Claude reset banner, optionally preceded by mise's launcher
version line, as `ProviderLimitError`; arbitrary judge/model quota prose still
fails as an ordinary non-quota error.

**Why:** A live Fable deliberation hit the real Claude subscription wall but
recorded `limits_reached:false`, preventing Hive's durable cooldown retry from
restarting the incomplete transcript after reset.

**Tests:** Expanded the packaged bench workflow regression to cover stderr
quota evidence, the observed stdout reset banner, and the model-prose false
positive guard.
