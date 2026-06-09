## [2026-06-09T10:07:58Z] e2e binary leading JSON values

**Action:** Fixed `bin/hive-e2e` leading class-option normalization so
`--json=true` and `--json=t` before `list` are relocated after the command and
emit the `hive-e2e-scenarios` JSON envelope instead of falling into the default
`run` pattern path. Falsey leading JSON forms such as `--json=false` and
`--no-json` are relocated too, but stay non-JSON. Removed the duplicate Thor
dispatch call so successful JSON commands emit a single parseable document.

**Validation:** `bundle exec ruby -Itest -Itest/e2e/lib test/e2e/lib/hive_e2e_binary_test.rb`
and `bundle exec rake e2e:lib_test`.
