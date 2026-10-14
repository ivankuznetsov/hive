---
title: Stabilize nested workflow views
type: changed
module: workflows
tags: [workflows, project, concurrency]
---

Project workflow operations now reject a nested switch to a different resolved
workflow directory before it can replace the outer registry view. The optional
stage-name compatibility value is also built only when the caller declares a
second positional block parameter.
