# Evidence sandbox coverage no longer depends on bubblewrap being installed

**Problem:** Routing controller-side terminal capture and the managed project
server through `ProjectCommandSandbox` made the test suite depend on a real
`bwrap` binary. Bubblewrap is installed on the maintainer's host but on no CI
runner, which produced three distinct failures against the exact-100% line gate:

- `ArtifactsCaptureToolkitTest#test_terminal_capture_is_controller_executed_and_receipted`
  errored with `project evidence sandbox requires bubblewrap`, aborting the
  shard before the coverage report ran and masking the two gaps below.
- Injecting the `project_sandbox_factory` seam to fix that error left the
  factory's production default (`CaptureToolkit#initialize`) reachable only
  from a bubblewrap-gated test.
- Eight `ManagedProjectServer` lines — the default spawner, the readiness poll,
  the `ready?` probe, and the `reap` `ECHILD` rescue — were reachable only from
  the already-`skip`ped real-bubblewrap test.

**Change:** Every sandbox line is now proven on hosts without bubblewrap, and
bubblewrap is used only to prove what only it can enforce.

- The capture-toolkit terminal test keeps the injected sandbox seam, and a new
  bubblewrap-gated test restores the read-only-source proof
  (`refute_path_exists mutation.txt`) that the seam cannot demonstrate.
- `capture_toolkit_coverage_gaps_test.rb` exercises the default
  `project_sandbox_factory`, which builds a real `ProjectCommandSandbox`
  without needing bubblewrap (the binary is resolved lazily, in `command_argv`).
- `ManagedProjectServer` gains a stub-sandbox lifetime test whose fake `bwrap`
  honours `--setenv` and then `exec`s the wrapped command, so spawning,
  readiness polling, output draining, and teardown all run for real, plus a unit
  test that teardown tolerates an already-reaped child.

**Verification:** running the artifacts and evidence test files with
`Hive::InvokedBinary.which("bwrap")` forced to `nil` reports exactly the same
uncovered lines as a run with bubblewrap present, so no coverage depends on the
host having it. Tests that genuinely need the real namespace `skip` with
`"bubblewrap is unavailable"`.

See [[artifacts]] and [[evidence]].
