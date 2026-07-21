---
title: Model registered projects in Rails
date: 2026-07-20
tags: [web, rails, architecture, projects]
---

Hive Web now wraps global-registry entries in a Rails `Project` model rather
than passing anonymous hashes through every controller and view. The model owns
typed name/path/state access, registered lookup, workflow/default discovery,
daemon enrollment policy, and the non-interactive `hive init` setup seam.

Project-scoped task, repository, workflow, agent, and idea surfaces now use the
same model. Existing gem adapters retain a narrow `fetch` compatibility method,
while Rails code uses named project behavior. This also moved setup warning
capture and resilient config reads out of `ReposController` and
`TasksController`.
