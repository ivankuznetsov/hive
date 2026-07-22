---
title: Align patrol evidence prompts with source verification
---

- Ordinary patrol now tells reviewers that every evidence snippet must be an
  exact substring of one claimed source line, without multiline excerpts,
  ellipses, or explanatory annotations.
- This keeps the existing fail-closed evidence validator intact while
  preventing source-backed findings from being discarded because the agent was
  not told the validator's exact wire contract.
