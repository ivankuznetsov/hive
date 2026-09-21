---
title: Support only current Hive formats
date: 2026-09-09
tags: [runtime, migration, schemas, cleanup]
---

Removed project migration commands, runtime cutover/sealing/import/manifests and
resume, historical upgrade survivor execution lanes, and superseded public schema
files. Explicit setup initializes a current SQLite database; existing current
storage retains identity and data. Updates validate the installed runtime instead
of migrating it. Unsupported folders remain visible with an agent conversion
guide, and obsolete configuration is rejected without automatic rewriting/moving.

Removed the old artifact stage capture runner/reader and one-time Bench/planner
repair paths. Public task JSON now uses the current semantic v2 contract; capture
readers reject v1. Current workflow-package updates, marker-based stages, journal
integrity, database custody and ordinary recovery remain. Added an offline agent
conversion guide shipped in the gem, with public URL remediation for installed
users, and updated current documentation. No live state was converted.
