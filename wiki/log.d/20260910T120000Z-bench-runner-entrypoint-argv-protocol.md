# Fix bench runner entrypoint discarding multi-argument commands

The bench runner image's bare `ENTRYPOINT ["/bin/bash", "-lc"]` broke
isolation.sh's exec-style argv protocol. Docker appends `docker run <image>
<cmd...>` arguments to the ENTRYPOINT argv, and bash's `-c` consumed only the
FIRST appended argument as its command string — the rest became unused shell
positional parameters. A call like `hb_isolated gate /work sh -c 'printf … >
/work/proof'` therefore ran bare `sh` and silently discarded `-c` and its
script; only the single shell-command-string protocol (isolation.sh gen mode,
gate_exec) still worked.

`templates/builtins/bench/runtime/hb-entrypoint.sh` now ships as a real file
(admitted by the runtime `.dockerignore`), is COPYed to
`/usr/local/bin/hb-entrypoint`, and dispatches: zero args run an interactive
login shell, one arg runs as a login-shell `-c` command string (unchanged
protocol), and two or more args exec as a verbatim argv array through a login
bash so the image environment matches the string protocol.

`test/unit/workflows/bench_test.rb`
(`test_packaged_runner_entrypoint_honors_both_command_protocols`) simulates
Docker's ENTRYPOINT+CMD argv assembly and asserts both protocols, including
argument-boundary preservation.
