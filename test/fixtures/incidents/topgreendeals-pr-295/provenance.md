# Sanitized provenance

This fixture preserves only the incident shape needed to exercise Hive's
finalize-to-babysitter authority boundary: PR number 295, two synthetic head
generations, disappearance from the open-PR list, a daemon claim takeover, and
the retained explicit merge timestamp `2026-07-16T23:05:50Z`.

Repository owner, URLs, branches, task identifiers, attempt identifiers, commit
SHAs, and non-merge timestamps are sanitized stand-ins. The response sequence
is replayed entirely from checked-in JSON. No test in this bundle may contact
GitHub or another network service.
