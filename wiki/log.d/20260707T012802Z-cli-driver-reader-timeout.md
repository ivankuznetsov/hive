# 2026-07-07 — bound e2e CLI stream readers after parent exit

`test/e2e/lib/cli_driver.rb` now treats stdout/stderr reader threads as part
of the CLI step timeout. If the direct `bin/hive` child exits but a descendant
keeps inherited capture pipes open, the driver marks the run timed out, signals
the spawned process group by `-pid`, and returns a nil exit code so normal
`expect_exit` validation fails instead of hanging the e2e suite. The regression
coverage in `test/e2e/lib/cli_driver_test.rb` uses a temporary Ruby fixture that
forks a sleeping child and exits immediately while keeping stdout/stderr open.
Pages: [[e2e]].
