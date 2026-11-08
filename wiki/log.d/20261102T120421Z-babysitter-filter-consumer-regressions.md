# 2026-11-02 — Clarify babysitter filter safety and passthrough checks

- The command and module pages describe `--no-ext-diff --no-textconv`
  injection for `log` and `show`, name the external-diff option family before
  discussing its prefixes, and explain Git 2.45.4's interpretation of glued
  `--filter=<spec>` as valueless `--filters`. That form is safe on the recorded
  old version because Git rejects its attached value before running a helper.
- Denied-token assertions identify the fixture case and launcher. A direct
  stub and generated-overlay regression requires separate-word
  `rev-list --filter blob:none` to reach real Git and preserve its stdout,
  stderr and exit status, including Git's ordinary error on the current binary.
- Both babysitter test files share the spelling fixture loader, and all three
  recording helpers share the capability-probe argv. The compatibility harness
  reuses repository and maintenance setup through an injected Git runner,
  retaining the selected binary, isolated environment and empty template.
- Verification: `bin/test` passed the policy, dry-run environment, acceptance,
  test-helper isolation and temporary-cleanup files (114 tests, 2,174 assertions,
  no failures/errors; one CI-only security-matrix skip). RuboCop passed all five
  changed Ruby files, and `git diff --check` passed.
