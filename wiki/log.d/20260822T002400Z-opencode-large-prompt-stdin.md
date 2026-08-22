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
Both the full Hive lifecycle fake executable and the skill-dependent OpenCode
integration driver read and record stdin, assert that the prompt is absent
from argv, and preserve the `/ce-plan` invocation check against that stream.
A CI-only failure exposed the stale integration assertion after transport
moved off argv; the regression now fails if either supervisor drops stdin or
silently moves an implementation-sized prompt back onto argv.
The live dogfood retry is the provider-backed proof that installed OpenCode
accepts the same transport for an execute worker.
