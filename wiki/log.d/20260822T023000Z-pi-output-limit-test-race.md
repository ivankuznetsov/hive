# Pi output-limit regression no longer races process exit

The Pi model-output-limit regression now keeps its fake provider alive after
emitting the terminal truncation event. Hive intentionally terminates that
process once the typed provider failure is known, so the test asserts the
resulting `TERM` status instead of racing the fixture's natural zero exit.

This is a test-harness correction only. Runtime classification remains
`model_output_limit`, and it continues to take precedence over the missing
review-artifact fallback.
