# 2026-10-13 — Pin upload-artifact v7.0.2 across workflows

**Change:** Dependabot advanced every `actions/upload-artifact` workflow pin
to the immutable v7.0.2 commit `cf430e030ddbb5b0abf93d22962f4752f3646cd9`.
The CI partition contract now tracks that pin, preserving its checks for raw
coverage and root-Minitest failure-evidence uploads.

**Boundary:** Artifact archive mode, retention, missing-file, and hidden-file
policies are unchanged.
