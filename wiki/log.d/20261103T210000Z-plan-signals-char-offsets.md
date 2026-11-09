# 2026-11-03 — Plan signals slice by characters, not bytes

- `Hive::PlanReview::PlanSignals` sliced plan text with `byteslice` using
  character offsets from `Regexp#match`, `String#index` and `#rindex`. Any
  multibyte character (em dash, arrows, quotes) before a match shifted the
  offsets, the slice landed inside a character, matching raised
  `ArgumentError: invalid byte sequence in UTF-8`, and the rescue reported it
  as `invalid_policy_limits`. Plan review then could not initialize
  ("plan review could not initialize from the current plan", exit 4) and the
  daemon redispatched it every minute (observed on hivedev C5: ~50 attempts).
- All five call sites (frontmatter, negation prefix/suffix/clause, evidence
  excerpt) now slice by character range. Regression test covers both byte
  parities before a matching word.
