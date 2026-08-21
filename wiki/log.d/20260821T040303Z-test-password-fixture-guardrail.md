# Obvious test password fixtures no longer park autonomous commits

Hive's staged-blob auto-commit safety check and post-fix review guardrail now
share a narrow exception for unmistakable placeholder password assignments
under `test/` or `spec/`, such as `operator.password = "password"`.

The shared `SecretPatterns.scan`, `match?`, and `redact` behavior remains
conservative. Production paths and arbitrary test literals still fail closed;
only a small exact allowlist of obvious fixture values is eligible. This keeps
real secret detection intact while allowing autonomous review repairs to add
ordinary authentication fixtures without requiring an operator waiver.
