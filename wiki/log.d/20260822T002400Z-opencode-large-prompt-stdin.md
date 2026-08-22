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

**Execution capability:** The same run then showed that file-only
workspace-write cannot satisfy 4-execute: Ox could author files but explicitly
reported that it could not install gems, run tests, or create the clean commit
the stage requires. OpenCode preparation now accepts only qualified Bash
patterns from a scoped policy and compiles them over a deny-first rule; bare
`Bash` is still rejected, while `Bash(*)` is a deliberate project opt-in.
Execute also removes its controller-owned task-state directory from
OpenCode's external file-tool roots. The reviewed plan stays in the prompt and
the full repository stays in the working directory, but a file-tool call can
no longer replace `task.md` or its live ownership marker.

An exit-zero OpenCode run with an empty terminal assistant message remains a
recorded malformed-output observation. Execute may nevertheless accept it when
the worktree supplies stronger completion evidence: the expected branch is
clean and has a new descendant commit. A dirty tree, missing commit, branch
mismatch, non-descendant commit, or nonzero exit cannot use this recovery.
