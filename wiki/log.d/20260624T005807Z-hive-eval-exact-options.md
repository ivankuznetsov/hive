---
date: 2026-06-24
slug: hive-eval-exact-options
pages: [testing]
---

Patched the checkout-local `bin/hive-eval` wrapper so Ruby OptionParser uses
exact long-option matching. This preserves the documented [[testing]] contract
that only `--scenario NAME`, `--report PATH`, and `--no-judge` are accepted;
abbreviations such as `--scen`, `--rep`, and `--no-j` now exit `64` before a
report is created.

Added focused subprocess coverage in `test/eval/support/reporter_test.rb` for
those abbreviated forms, then verified the reporter suite and targeted RuboCop
pass. No page was added, so [[index]] did not need a catalog update. Did not
edit compiled [[log]], and did not run `qmd update` or `qmd embed`.
