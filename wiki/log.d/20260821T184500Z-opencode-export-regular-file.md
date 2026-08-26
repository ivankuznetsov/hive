# Capture OpenCode sanitized exports through a regular file

- Reproduced OpenCode 1.18.18 losing the tail of a large sanitized export when
  stdout is a pipe: the process exited zero after 245,760 of 983,152 bytes,
  whereas redirecting the identical export to a regular file produced valid
  JSON.
- Replaced Hive's inspection stdout pipe with an unlinked private temporary
  file. Hive reads no more than one byte beyond the existing four-MiB parser
  limit, reports oversize evidence explicitly, and removes the sanitized data
  when the inspection returns.
- Kept stderr bounded, process-group timeout cleanup, syntax retries, strict
  session/terminal correlation, and overlay cleanup unchanged.
- Added a lifecycle regression that requires inspection stdout to be a regular
  file. The complete Pi/OpenCode benchmark and both judge families remain live
  validation until their final artifacts are assembled.
