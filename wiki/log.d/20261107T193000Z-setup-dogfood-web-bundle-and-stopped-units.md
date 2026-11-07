## 2026-11-07 — `hive setup` on dogfood: web bundle root and stopped units

- `web_bundle` failed with `KeyError: key not found: "agent-cli-runtime"` on
  dogfood deployments: `AppBundle.agent_cli_runtime_root` fetched the gem spec,
  which only packaged installs activate. It now falls back to
  `<hive_cli_root>/components/agent-cli-runtime` when no spec is loaded.
- `daemon_service`/`babysitter_service` failed with "retained unverified
  recovery evidence" whenever the unit was stopped: systemd keeps
  `ExecMainStartTimestampMonotonic` after stop with `MainPID=0`, and the
  journal rejected that pid-less start as incoherent before writing anything.
  `Manager::Inspection` now drops the start with the non-positive PID.
  Independent of the web bundle failure.
- Pages: [[modules/agent_cli_runtime]], [[modules/user_service]].
