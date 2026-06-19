## [2026-06-19T21:27:08Z] init/doctor - visual artifact prerequisites

**Action:** Added opt-in visual-artifact prerequisite provisioning to `hive init` and matching non-fatal readiness rows to `hive doctor`. Init now checks host-global `ffmpeg`/`asciinema`, offers package-manager install or a manual command, and can connect screenote by validating a pasted REST API token before writing `screenote.{base_url,api_token}` to global config only. Non-TTY init skips the flow silently, skipped prompts complete normally, and doctor reports missing optional prerequisites as warnings rather than failing.

**Coverage:** Added `Hive::VisualArtifactsReadiness`, `CaptureToolingInstaller`, `VisualArtifactsPrereqs`, screenote onboarding tests, env-scrub regression coverage, doctor visual readiness rows, and init integration coverage for non-TTY silence plus interactive skip. Updated [[commands/init]], [[commands/doctor]], [[stages/artifacts]], and `docs/visual-artifacts.md`.
