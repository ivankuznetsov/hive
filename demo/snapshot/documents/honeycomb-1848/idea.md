---
slug: registry-layout-package-manifest-schema-260709-1f1a
created_at: 2026-07-09T11:19:54Z
original_text: |
  Registry layout + package manifest schema. Define the honeycomb package format and repo structure: packages/<name>/ containing workflow.yml (hive DescriptorParser-valid), instructions/ (the stage instruction files), README.md, and manifest.yml (name, version semver, author, license, hive min version, permissions summary auto-derived from the descriptor, sha256 of every file). A generated top-level catalog index (catalog.json) lists all packages with their manifest data for CLI consumption. Ship a validator script (ruby, no deps beyond stdlib+yaml) that checks: descriptor parses via hive's DescriptorParser when hive gem present (optional soft-dep), manifest completeness, sha integrity, instruction files referenced by descriptor all exist. Reuses conventions from hive-bench corpus entries (manifest+sha pattern).
---

# registry-layout-package-manifest-schema-260709-1f1a

Registry layout + package manifest schema. Define the honeycomb package format and repo structure: packages/<name>/ containing workflow.yml (hive DescriptorParser-valid), instructions/ (the stage instruction files), README.md, and manifest.yml (name, version semver, author, license, hive min version, permissions summary auto-derived from the descriptor, sha256 of every file). A generated top-level catalog index (catalog.json) lists all packages with their manifest data for CLI consumption. Ship a validator script (ruby, no deps beyond stdlib+yaml) that checks: descriptor parses via hive's DescriptorParser when hive gem present (optional soft-dep), manifest completeness, sha integrity, instruction files referenced by descriptor all exist. Reuses conventions from hive-bench corpus entries (manifest+sha pattern).

<!-- WAITING -->

NAMING (2026-07-09): a published workflow package is called a HONEYCOMB.
Use the term in all user-facing surfaces: manifest field docs, CLI output,
CI comments, README/catalog. The public catalog page is hive.sh/honeycombs.
