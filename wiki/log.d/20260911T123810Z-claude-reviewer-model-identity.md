# Preserve main Claude reviewer identity across subagent usage

Mixed-model Claude results previously selected the first `modelUsage` key as the
reviewer model. A Haiku helper could replace Opus, causing otherwise successful
adversarial reviews to lose family attestation and block as `coverage_failed`.
Track main-conversation identity independently, ignore child model events, and
leave ambiguous totals unknown. Preserve aggregate token counts.

`request-review` can rerun successful adversarial output with unknown reviewer
family while preserving prior evidence and the successful primary review.
Regression tests cover mixed key ordering, main/child events, identity precedence,
unknown identity, and recovery without waiving independence.

The three observed live failures have the matching receipt signature; their raw
streams have not established whether each Haiku entry came from a subagent.
