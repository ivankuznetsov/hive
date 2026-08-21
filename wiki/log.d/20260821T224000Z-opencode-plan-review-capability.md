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
