# 2026-08-30 — Centralize new-idea project resolution

The TUI snapshot now owns the ordered new-idea admission list and exhaustive
entry/name resolution states. Numeric dashboard scope is consumed once, while
picker refresh and submit revalidation retain exact project identity and fail
closed on missing, unhealthy, or ambiguous targets.

Plain and image-rich submissions share one latest-snapshot preflight. A blocked
attempt dispatches nothing, keeps the composition and staged attachments, and
requires an explicit valid picker selection before retry. The documented
boundary prevents stale-position substitution while retaining the known
post-preflight race in the existing live name-based registry lookup.
