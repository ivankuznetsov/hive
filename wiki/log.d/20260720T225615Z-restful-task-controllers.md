---
title: Make task endpoints small Rails resources
date: 2026-07-20
tags: [web, rails, architecture, controllers]
---

Hive Web's task routes keep their established URLs and helpers, but now target
small namespaced resource controllers with standard `show` or `create`
actions. `TasksController` renders only the task itself; diff, log, media,
approval, rejection, drop, run, recovery, answers, and intervention each have
one focused controller over `Task` or `Hive::Web::Dispatcher`.

`Tasks::BaseController` centralizes only the common registered-project and task
lookup boundaries. Stale-page mutations still intentionally avoid loading a
fresh task snapshot before handing their rendered `from` guard to the native
dispatcher, preserving the existing race-safety contract.

Moving the log read behind `Task#latest_log` also retired the old Brakeman
controller-path false positive. The obsolete ignore is removed, and focused
log-route coverage now pins unknown-project and unknown-task 404s before any
filesystem read.
