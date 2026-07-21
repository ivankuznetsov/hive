---
title: Give Hive Web tasks a Rails model
date: 2026-07-20
tags: [web, rails, architecture, tasks]
---

Hive Web now represents the selected status row as a filesystem-backed Rails
`Task` model. The model owns task lookup and read behavior: workflow-aware
artifacts, media manifest and containment checks, unanswered brainstorm
questions, worktree presence, and the bounded log tail.

`TasksController` now concentrates on HTTP concerns and dispatching mutations,
while task views receive `@task` rather than an anonymous status `@row`. The
media reader also enforces the documented single-filename contract directly,
so callers outside the route constraint cannot normalize a traversal-shaped
name into an allowed basename.
