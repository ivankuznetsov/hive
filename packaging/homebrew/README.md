# Homebrew packaging

- `hive.rb.erb` — the formula template (single source of truth). The release
  pipeline renders it via `packaging/render.rb` with `{version, sha256_gem}`.
- `tap/` — **staging area** for the external `ivankuznetsov/homebrew-hive`
  tap repository, which does not exist yet. Its contents (`Formula/hive.rb`,
  `.github/workflows/update-formula.yml`, `README.md`) are the exact files to
  push into that repo when it is created during the release runbook
  (`docs/RELEASING.md`, plan unit U5). `Formula/hive.rb` here is bootstrapped
  for v0.1.0; from v0.1.1 onward the tap's workflow regenerates it on each
  release dispatch.

Once the tap repo exists, copy `tap/*` (including dotfiles) into its root.
This staging layout is a deliberate choice — flagged for review — because an
agent cannot create the external repo, only author the files it will hold.
