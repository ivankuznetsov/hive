# Pipe Pi prompts over stdin

**Problem:** A real Webmail execute prompt exceeded Linux's per-argument size
limit before Pi could start, producing `Errno::E2BIG: Argument list too long -
pi`. Hive treated Pi like a positional-prompt CLI even though Pi natively reads
a non-TTY stdin stream into its initial message.

**Change:** Added the explicit `:piped_stdin` agent-cli-runtime prompt
transport and assigned it to the built-in Pi profile. Unlike Codex's `:stdin`
transport, it does not add a `-` argv marker. Hive now writes Pi's complete
prompt through its owner-private temporary stdin file, leaving only bounded
flags in argv. A 256 KiB fake-Pi regression test covers the size that formerly
failed at process spawn, and the package/Hive compiler tests pin the exact
argv/stdin split.

**Operational consequence:** A daemon recovery can launch large Pi execute
work without an operator retry or plan truncation. Authentication, model
routing, tools, timeout, output parsing, and provider error detection are
unchanged.
