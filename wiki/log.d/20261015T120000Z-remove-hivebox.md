# 2026-10-15 — Drop the Hivebox Docker distribution

- Hive now has two supported routes: native Hive (Homebrew on macOS arm64,
  AUR on Arch, `install.sh` on glibc Linux, WSL with systemd on Windows) for
  people who want to tinker, or the hosted cloud product for everyone else.
  ADR-055 in [[decisions]] records the decision and supersedes ADR-037's
  Hivebox container deployment mode plus the Hivebox-specific consequences of
  ADR-035/ADR-036.
- Removed: `packaging/docker/` (Dockerfile, entrypoint, compose example,
  `install-box.{sh,ps1}` and their harnesses, image smoke), the root
  `.dockerignore`, `.github/workflows/hivebox-recover.yml`, the release
  image build/smoke/promotion jobs, the Windows installer CI job, the
  install-smoke installer checks, `Hive::Web::Supervisor`,
  `Hive::Paths.hivebox_supervisor_pid_path`, the `hivebox_supervisor`
  launch-coverage row and legacy process discovery, and the container-only
  `HIVEBOX_SUPERVISOR_PID`, `HIVEBOX_SESSION_SECRET`, `HIVEBOX_REPOS_DIR`, and
  `HIVEBOX_PRECOMPILED_ASSETS` reads (with the `hivebox` header branding).
  The Telegram settings page now always asks the operator to restart the bot.
- Kept: GitHub device-flow sign-in and owner claim, `/health?deep=1`, the six
  deprecated native-web `HIVEBOX_*` aliases, the closed
  `hive-artifact-capture.v2` evidence type literal `hivebox`, and the bench
  runner `Dockerfile.runner`. Published GHCR images and installer URLs stay
  in place without updates.
- Docs: README, install.md, FAQ (with a Hivebox-to-native migration note),
  getting-started, architecture, permissions, RELEASING, the site companion,
  OpenClaw README, the canonical `hive` skill (OpenClaw projection
  regenerated), and the web/daemon/setup/config/testing/dependencies/gaps
  wiki pages. Hivebox-only gaps are closed; [[gaps]] records the open
  question of when to drop the deprecated native aliases.
