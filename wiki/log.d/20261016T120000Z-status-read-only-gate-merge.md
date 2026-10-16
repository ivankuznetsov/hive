# 2026-10-16 — Read-only status gate after the Hivebox removal merge

- Main removed the root `.dockerignore` with the Hivebox Docker distribution.
  The `test:status_read_only` Docker gate now filters its `COPY . /app` build
  context with the Dockerfile-scoped
  `test/support/status_read_only.Dockerfile.dockerignore`, so `.git`, local
  state, and secrets stay out of the candidate image.
- The gate's evidence upload uses the repository-wide pinned
  `actions/upload-artifact` revision.
- Added unit coverage for malformed-mountinfo and failed post-fork reset
  confirmation (both fail closed) and for non-storage `Unavailable` errors
  during attempt-repository initialization.
