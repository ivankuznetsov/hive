# Artifact revision records malformed proof candidates

Outcome-evidence review now records a rejected candidate when a reviewer marks
the same claim `revise` for using the wrong proof kind. Acceptance remains
strict: an accepted or blocked verdict cannot admit that mismatch, and
publication still revalidates the full contract.

Previously the controller checked the acceptance proof-kind rule before it
could append the review. The candidate stayed pending, so every daemon retry
sent the identical evidence back to another reviewer and never delivered the
review guidance to a fresh producer. Persisting the immutable failed attempt
lets the existing targeted-recapture loop advance autonomously.
