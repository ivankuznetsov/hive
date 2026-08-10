# Nested web Gemfile for the root Brakeman scan

**Date:** 2026-07-27

**Change:** CI now passes `--gemfile web/Gemfile` to the repository-root
Brakeman scan and a focused workflow-contract test pins both the dependency
source and the absence of `--path web`.

**Why:** Adding the workflow-publication contract updater introduced the first
top-level `script/` directory without a legacy `script/rails` executable.
Brakeman 8.0.5 then stopped inferring a Rails generation, selected its legacy
ERB parser, and failed while mutating Ruby 3.4's frozen generated ERB source.
Reading the nested Gemfile keeps the existing full-root scan over Hive libraries
and the nested Rails web application while selecting Brakeman's Erubi path and
retaining version-aware Rails checks.

**Validation:** The exact root command detected Rails 8.1.3 and completed with
0 errors, 0 security warnings, and 35 reviewed ignored warnings. The focused CI
workflow contract test also passed.
