# Pi browser evidence uses one complete argv

Live Webmail artifact dogfood showed that Pi naturally called the typed
`evidence_browser` tool with both `command: "open"` and
`argv: ["open", issued_origin]`. The generated extension then prepended the
separate command to the already-complete argv and invoked Hive as
`evidence browser open open URL`, which failed the exact issued-origin gate.
Equivalent retries could never succeed and the otherwise productive artifact
attempt ended with empty producer output.

The tool contract now has one required non-empty `argv` field and forwards it
verbatim after Hive's controller-owned `evidence browser` prefix. Its
description explicitly says the first item is the action verb. This matches
the terminal and server tools' single-argv shape and the artifact prompt's
documented command examples.
