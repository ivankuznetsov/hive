## Semantic E2E coverage catalog and release selection

**Action:** Added the stable `test/e2e/coverage.yml` taxonomy, joined every
current scenario to one primary coverage ID, and added deterministic semantic
discovery plus additive `run --coverage` / `run --profile release` selection.
Semantic runs write a versioned `selection.json` companion while existing
scenario inventory and report v1 payloads remain unchanged.

**Evidence:** Focused catalog, scenario-parser, runner, binary, schema, and E2E
harness-library tests cover invalid and duplicate mappings, pending required
gaps, root-confined references, exact/substring discovery, JSON/prose output,
unique active-primary execution, and preflight before run creation.
