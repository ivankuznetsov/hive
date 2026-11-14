## 2026-11-14 — Durable attempts tag and reap their Podman containers

- New `Hive::Attempts::ContainerReaper`. The supervisor writes
  `open/<attempt_id>/containers/containers.conf` with
  `[containers] annotations = ["hive.attempt=<id>", "hive.project=<name>", {append=true}]`
  and sets `CONTAINERS_CONF_OVERRIDE` for the worker, so every rootless
  `podman run`/`create` in the attempt is annotated. Isolated agent launches
  keep the variable. An inherited operator override is left alone and the
  attempt logs `untagged`; an agent's own `CONTAINERS_CONF` still applies.
- On every supervisor exit path, before ScopeReaper, it lists
  `--filter annotation=hive.attempt=<id>` and runs
  `podman rm --force --volumes`, bounded by one 30 s deadline (the
  quiescence grace while quiescing). Anonymous volumes go with their
  container; named volumes stay. A notable result is one
  `hive-attempt: attempt_containers {…}` line in the attempt log. Failures and
  timeouts never change the attempt outcome.
- `LostOutcomeProcessor` reaps a lost attempt's tagged containers once worker
  cleanup is safe and logs the daemon event `attempt_containers_reaped`.
- New project key `attempt_reap_containers` (default `true`). `false` reaches
  the supervisor as `--reap-containers false`; the attempt gets neither the
  tag nor the reap.
- Motivation: agent Postgres containers (`todero-babysit64-pg` on
  `0.0.0.0:55432`, `todero-patrol-navigator-pg` on `0.0.0.0:55440`) lived in
  `libpod-*.scope` outside the attempt scope and survived for days. Verified
  live on Podman 6.1.4. Remaining gaps are in `wiki/gaps.md`.
