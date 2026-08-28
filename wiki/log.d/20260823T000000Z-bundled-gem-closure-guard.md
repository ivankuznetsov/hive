# Bundled-gem requires in lib/ are now guarded against the gemspec closure

**Problem:** Twice (base64, then rexml) Hive shipped with lib/ code requiring
a Ruby 3.4 bundled-or-removed gem that was not guaranteed present, and both
times the fix — an explicit `spec.add_dependency` — landed only after a stock
install crashed with LoadError. Nothing failed in CI; the knowledge lived in
gemspec comments and wiki rows.

**Fix:** `test/unit/gemspec_test.rb` now has
`test_lib_requires_of_bundled_or_removed_gems_are_in_the_runtime_dependency_closure`.
It scans every `require "<name>"` under `lib/`, keeps non-relative,
non-hive top-level names, and fails when such a name appears on the Ruby 3.4
bundled-or-removed list (abbrev, base64, bigdecimal, csv, drb, getoptlong,
mutex_m, nkf, observer, resolv-replace, rexml, rinda, syslog) without being
covered by the runtime dependency closure resolved from `hive.gemspec`
(direct deps plus transitive closure via `Gem::Specification.find_by_name`).

**Related declaration:** `lib/hive/model_pricing.rb`,
`task_workspace/usage.rb`, and `task_workspace/semantic_snapshot.rb` require
`bigdecimal` directly, but it was only covered transitively (via dry-types).
The gemspec now declares `spec.add_dependency "bigdecimal", ">= 1.4"`
explicitly, matching the erb/faraday direct-require convention, and
`Gemfile.lock` carries the relock.

**Verified:** removing the new declaration still passes today because of the
transitive carrier, but requiring an uncovered bundled gem (e.g. `abbrev`)
fails the guard immediately.
