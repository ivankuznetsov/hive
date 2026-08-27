# Advisory TUI latency no longer strands exact-head automation

The absolute TUI latency workflow now applies `continue-on-error` to the
measurement step instead of the whole job. Hosted-runner budget overruns remain
visible in the step summary and retain their failure-evidence artifact, while
the advisory check finishes green so exact-head automation can reach a terminal
result. Required CI still enforces row completeness and archive-size scaling.
