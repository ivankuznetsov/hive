# Artifact roles accept a prose preamble before final JSON

**Problem:** The artifact role parser accepted explanatory prose before a
fenced JSON result, but rejected the equivalent response when the same complete
JSON object was emitted without a Markdown fence. A live Pi producer completed
all writes and returned its valid evidence manifest after a short status
preamble, causing Hive to discard the attempt as malformed.

**Change:** Artifact roles may now return one unfenced JSON object after a prose
preamble and blank-line boundary. The object must still be the final content;
trailing prose, multiple fenced objects, duplicate keys, oversized output, and
non-object roots remain rejected.

**Verification:** The stage tests cover the accepted live-response shape and
retain rejection coverage for trailing prose.
