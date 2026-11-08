# Drop command test waits for pid file contents, not existence

`DropCommandTest#wait_for_pid_file` polled `File.exist?` and then parsed the
file in one shot. The spawned child writes its nested pid with `File.write`,
which creates the file before the digits land in it, so the parent could read
`""` and fail with `ArgumentError: invalid value for Integer(): ""`. That
surfaced as an intermittent single-error failure in CI coverage shard 5/6.

The helper now mirrors the already-hardened
`test/unit/process_kill_test.rb#wait_for_pid_file`: it polls until the contents
parse as a pid, uses a monotonic deadline, and `flunk`s with a clear message on
timeout instead of raising from `Integer()`.

This is a test-harness correction only. No runtime behavior changed, and only
`lib/**/*.rb` is measured by the coverage gate, so the shared helper shape
carries no coverage impact.
