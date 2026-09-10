# CLI usage contracts preserve the newly merged digest boundary

The final main refresh includes the daily digest command added by #1407.
Its pre-dispatch `hive-digest` / `usage` contract now lives in
`lib/hive/commands/digest.rb` with the other command-owned declarations.
Removing the former launcher registry must not drop a contract added while
the extraction branch was under review.

A focused regression reproduced the missing declaration before the fix;
the boundary resolver and launcher inventory cover it. The runtime component
test helper retains current main's built-in profile executable selection.
The existing JSON schema and exit behavior are preserved.
