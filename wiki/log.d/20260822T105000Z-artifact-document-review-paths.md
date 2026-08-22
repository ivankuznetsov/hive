# Artifact prompts require distinct document review files

Artifact producer guidance now states the representation-path rule at the
point where document evidence is introduced: a document original and its
plain-text review must be different files, and producers should create the
review with `evidence_write`. Only controller-issued visual captures may reuse
one PNG, JPEG, WebP, WebM, or MP4 source path for both roles before custody
materializes distinct retained copies.

This closes a dogfood failure where a producer returned one Markdown file as
both the original and a nominal `text/plain` review. The evidence contract
correctly rejected the whole result as `outcome evidence representation paths
must be unique`, but the prompt had made the exception more prominent than the
general rule.
