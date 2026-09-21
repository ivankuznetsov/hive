# Pi can start a non-Hive application for browser evidence

**Problem:** Non-Hive visual evidence told producers to start the changed
application on Hive's issued port. Codex can keep a child in its attempt process
group, but managed Pi intentionally has no Bash tool. Its only executable tool
was the synchronous terminal recorder, which waited 30 seconds for a Rails
server, killed it at the evidence timeout, and returned before the model could
use the browser. The documented Pi path was therefore impossible.

**Change:** Managed Pi visual producers now receive `evidence_server`. The
controller accepts one executable confined to the frozen repository, starts it
on the issued loopback port inside a credential-free bubblewrap PID/filesystem
sandbox, waits for HTTP readiness, and keeps it alive until the capture toolkit
closes. The repository is read-only except for conventional runtime directories
(`log`, `storage`, and `tmp`), and the sandbox exposes no operator home,
credential files, DBus, SSH agent, or arbitrary host filesystem. Hive owns
bounded diagnostics, process identity, and teardown.

Dogfooding also exposed that controller-side terminal capture escaped the
producer's read-only mount: a producer used `evidence_terminal` to create an
untracked root-level canary while probing detached processes. Terminal targets
now run through the shared project-command sandbox as well. Their transcript
keeps the requested argv, but the command cannot mutate committed source or
inherit operator credentials.

**Verification:** Command, runtime-policy, capture-toolkit, and managed-server
tests cover gateway admission, tool exposure, source-confined sandbox mounts,
real HTTP readiness, terminal source-write denial, duplicate start refusal,
and cleanup. The real Webmail Rails server also reached readiness through the
same managed path and released its issued port cleanly.
