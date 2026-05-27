# homebrew-hive

Homebrew tap for [hive](https://github.com/ivankuznetsov/hive) — a
folder-as-agent pipeline for autonomous software tasks.

## Install

```sh
brew install ivankuznetsov/hive/hive
```

Or tap first, then install:

```sh
brew tap ivankuznetsov/hive
brew install hive
```

If Apache Hive (the SQL-on-Hadoop tool) shadows the `hive` binary on your
PATH, use the `hv` alias instead.

## Maintenance

`Formula/hive.rb` is updated automatically and should **not** be hand-edited.
On each release, hive's release workflow sends a `repository_dispatch`
(`hive-release`) event carrying `{version, sha256_gem}`. The
`.github/workflows/update-formula.yml` workflow here renders the formula from
hive's own `packaging/homebrew/hive.rb.erb` template (single source of truth)
and commits the result.
