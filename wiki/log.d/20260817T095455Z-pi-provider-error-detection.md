# pi provider refusals are detected instead of read as empty output

`Hive::Agent`'s stream scan gated provider-limit detection on the event's
`type` (`error`, `turn.failed`, `rate_limit_event`, failed `result`). pi never
uses those: it keeps the envelope type (`message_start` / `message_end`) and
reports a refused turn through `stopReason: "error"` plus `errorMessage`, then
exits 0. A refusal therefore reached Hive as a clean run that produced nothing,
and `7-artifacts` recorded `outcome_evidence_invalid` ("reviewer output is
missing or oversized") — an operator-owned terminal error with no dispatch
command, so the daemon parked the task instead of holding it on the provider.

Observed on `webmail.sh:build-the-first-implementation-milestone-260816-6240`:
several hundred OpenRouter `402 Prompt tokens limit exceeded` responses across
eight reviewer attempts, every one exiting 0, task stuck ~6 hours.

Provider shape now lives with the provider. `agent-cli-runtime` gained
`ErrorExtractors` and a per-profile `error_extractor` (defaulting to the
previous type-based shapes, so no profile changes behaviour), exposed as
`AgentCliRuntime.extract_provider_error` returning
`{provider:, status_code:, message:}` with the text redacted. Hive consults it
first and treats HTTP 402/429 — or limit wording — as a provider limit.

Notably `AgentLimit::LIMIT_PATTERNS` would not have matched this text either:
"Prompt tokens limit exceeded" fails the `token[\s-]?limit` alternation because
the word is plural, and no pattern covers 402. Classifying on the provider's
own status code avoids depending on wording that varies per provider.

Packaging note: this ships as `agent-cli-runtime` 0.2.1, a patch on the already
published 0.2.x line, so `hive.gemspec` keeps `~> 0.2.0` and installed Hive
resolves the new bytes without a constraint change. Both lockfiles still carry
the version — `web/Gemfile` resolves `hive-cli` and `agent-cli-runtime` as path
gems too, and the web jobs run `bundle install` frozen, so relocking only the
root fails web setup outright.

See [[modules/agents]] and [[dependencies]].
