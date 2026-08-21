# pi runs were never metered

`token_usage` held 13,980 rows: claude 7,168, codex 5,895, profile 667,
grok 251 — and pi zero. Not few. None, ever.

Two independent gaps, both in `UsageExtractors`:

- `usage_hash` inspected `usage`, `token_usage`, `event.usage`,
  `event.message.usage`, `info`, `response` and `item`, but not
  `message.usage`, which is where pi reports it. Every pi event returned nil.
- The token readers accepted `input_tokens`/`inputTokens`/`prompt_tokens`
  spellings; pi emits bare `input`, `output`, `cacheRead`, `cacheWrite`. Even
  a correctly located hash produced all-nil counts.

The existing pi test passed because it asserted an assumed shape — a
top-level `usage` with `prompt_tokens` under `type: result` — that pi does not
emit. The new test uses a verbatim event captured from a live run.

Bare spellings are matched last, so a provider reporting explicit `*_tokens`
keys keeps its previous reading.

Downstream this is why a task's usage panel reads "Token usage unavailable"
and "Sessions covered 0 of 0": with no rows, provider, model, billing route
and the API-equivalent price all fail closed before pricing is consulted.

See [[modules/token_usage]].
