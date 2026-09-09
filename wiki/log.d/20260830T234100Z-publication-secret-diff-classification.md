# Publication secret scans distinguish references from credentials

GitHub publication now scans native Git patches by changed path and added hunk
line instead of applying the prose/log regex bundle to all raw diff bytes.
Password-shaped Ruby references share the review guardrail's runtime-reference
classification, so ordinary password plumbing does not stop a PR as a supposed
committed secret. Shell substitutions remain blocked because their commands can
contain literal material.

Literal assignments, mixed reference-plus-literal values, token patterns,
secret-shaped paths, malformed patch input, PR titles, and PR bodies remain
fail-closed. Removed base bytes no longer block a patch that deletes a secret.
The shared raw `scan`, `match?`, and `redact` APIs remain conservative.
