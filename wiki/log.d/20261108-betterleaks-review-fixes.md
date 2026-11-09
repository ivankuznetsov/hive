# Betterleaks packaging review fixes

Accept verified archives when post-transfer hashing crosses the download
deadline. Fail fast for missing/unusable curl and non-transient exits, report
safe last-failure categories on deadline exhaustion, and route extraction
errors through the sanitized script failure handler. Normalize selected tokens
only after rejecting CR/LF. Retain proxy/certificate environment configuration
and document that `--disable` suppresses curlrc files.

Cover every emitted diagnostic category through the strict candidate
forwarder, derive budget text from `DOWNLOAD_BUDGET`, use a shell child for the
bounded subprocess test, and assert GH_TOKEN scope throughout packaging jobs
alongside the required global GITHUB_TOKEN packaging-step scope. Preserve the
existing release E2E producer-attestation credential. Production endpoint and other
architecture verification limits remain in `wiki/gaps.md`.
