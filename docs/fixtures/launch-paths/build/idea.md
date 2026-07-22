# Build input: make health visible

> **Deterministic replay fixture.** This is synthetic sample input, not the
> transcript of a provider-backed run.

Starting from this empty Git repository, create a minimal Rack service with a
`GET /healthz` endpoint. Return JSON containing `status`, the application
version, and the current git SHA. Add a focused test, document how to run it,
use `unknown` when Git metadata is unavailable, and never expose environment
variables or secrets.
