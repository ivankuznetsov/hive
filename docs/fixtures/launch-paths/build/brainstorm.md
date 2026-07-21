# Build brainstorm

> **Deterministic replay fixture.** This artifact demonstrates the shape a
> completed brainstorm can leave behind.

- Bootstrap only the files a tiny Rack service and direct unit test need.
- Keep the endpoint read-only and the response independent of environment data.
- Define the version in the application rather than assuming an existing app.
- Resolve the SHA once at process boot; use `unknown` when git metadata is not
  present in the release artifact.
- Cover the response and no-git fallback without starting a network listener.

Decision: create one Rack endpoint plus a focused test runnable from an empty
repository after `bundle install`.
