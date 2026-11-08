# Verify stale predecessor liveness against current task leases

The stale predecessor liveness fix still applies after task locks moved to the
runtime control plane. Updated the status documentation to describe typed task
leases and fenced dead-holder reclamation instead of the former `.lock` file.
The Patrol Fix regression fails on current main and passes on the PR; the
current dead-holder reclamation test also passes.
