---
title: Patrol Fix evidence closure reaches its inert terminal
type: change
date: 2026-08-28
tags: [patrol, patrol-fix, closure, workflow]
---

Verified evidence closure now supplies the alternate terminal authority for a
Patrol Fix task whose work was already delivered outside its current workflow
stage. The valid closure receipt authorizes only the move to `6-done`; Patrol
Fix status archives that terminal task without inventing a publication receipt,
and guarded archive does not dispatch the inert controller terminal as an
agent stage.
