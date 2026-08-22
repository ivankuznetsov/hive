# OpenCode streams implementation-sized prompts

**Observed:** The Webmail.sh OpenCode dogfood passed mandatory plan review with
a 141 KB plan, then failed before its execute worker launched:
`Errno::E2BIG: Argument list too long`. The prepared invocation placed the
complete plan-derived prompt in one positional argv element. Linux bounds one
argument below the overall `ARG_MAX` budget, so the valid reviewed artifact was
large enough to make `execve` reject the process.

**Fix:** The built-in OpenCode profile now uses the CLI's non-TTY stdin prompt
transport. Prepared invocations keep the same discrete run, model, variant,
directory, permission, and JSON-output arguments while carrying the rendered
prompt in `stdin_data`. Hive's dedicated OpenCode supervisor now feeds those
bytes through an owner-private temporary file; the generic supervisor already
did so for other stdin-style profiles, but the specialized prepare/inspect
lifecycle previously dropped them.

**Regression:** Component preparation asserts the ordinary argv/stdin shape
and a 150 KB prompt that remains byte-identical on stdin and absent from argv.
The full Hive lifecycle fake executable reads and records stdin so a dropped
prepared payload fails the regression instead of passing on argv shape alone.
The live dogfood retry is the provider-backed proof that installed OpenCode
accepts the same transport for an execute worker.
