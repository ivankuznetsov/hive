# 2026-07-03 — scope HIVE_CLI_ROOT to the managed bundle (image-smoke fix)

The v0.3.4/v0.3.5 hivebox image smoke failed at `db:prepare`: the runtime
HIVE_CLI_ROOT export (added for the managed bundle) re-pointed the web
Gemfile's hive-cli path source under the image's PREBUILT /app/web bundle
(built against ".." = /app, while the runtime hive is the installed gem, so
its root differs). `hive web` now exports HIVE_CLI_ROOT only when serving
the managed bundle (`app_dir == AppBundle.app_dir`); source checkouts and
HIVEBOX_WEB_APP_DIR overrides keep their build-time ".." resolution.
Verified by running the release job's exact sequence locally: gem build →
image build → `packaging/docker/smoke.sh` → PASS (first pass since v0.3.2).
Pages: [[commands/web]].
