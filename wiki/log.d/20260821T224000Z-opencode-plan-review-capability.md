## OpenCode plan review capability

**Action:** Added OpenCode to the committed `ce-doc-review` capability mapping.
OpenCode already installs the same pinned Compound Engineering plugin used for
brainstorm, planning, code review, and browser testing, but the document-review
entry omitted it. A configured OpenCode primary plan reviewer therefore passed
route preparation and then failed as `unsupported` with `key not found:
"opencode"`. The manifest now exposes `/ce-doc-review` with the plugin's
`skills/ce-doc-review/SKILL.md` probe, backed by a direct manifest regression.

**Dogfood evidence:** The Webmail.sh OpenCode workflow reached mandatory plan
review after producing a complete plan; the missing capability was the exact
whole-document blocker. Exact adversarial model routing remains project config,
not part of this capability fix.

That same run exposed an identity gap: top-level `models.plan_review*`
overrides change the model and effort actually launched for each review role,
but only the raw route row was fingerprinted. Correcting the adversarial model
therefore replayed the old blocked record. The policy and configuration
fingerprints now include only the three plan-review routing keys; unrelated
execute and workflow model choices do not rekey a review.

The fresh review then proved that the adapter's default skill probe looked up
the stock ambient OpenCode profile while the actual launch used the
project-prepared profile. It consequently instructed the operator to install a
plugin already present in `agents.opencode.plugins`. `HiveRunner` now exposes a
capability probe backed by its project config, and `CeDocReview` selects it by
default; custom test/embedding probes remain injectable.
