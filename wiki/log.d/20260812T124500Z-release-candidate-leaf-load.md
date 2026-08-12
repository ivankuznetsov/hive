---
title: Release candidate skill builder uses a leaf load
module: release-candidate
tags: [release, packaging, agent-skills, dependencies]
problem_type: regression
---

The release-candidate artifact builder now loads the canonical Hive skill leaf
instead of requiring the complete Hive runtime. This lets a committed source
export build its skill artifact before `agent-cli-runtime` and the other
candidate gem dependencies are installed. A `--disable-gems` regression pins
that bootstrap boundary.
