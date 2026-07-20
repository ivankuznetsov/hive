---
title: Native web mobile status layout
date: 2026-07-20
tags: [web, mobile, responsive, daemon]
---

The native status page now keeps the idea composer within narrow mobile
viewports even when registered projects have long names. Its project selector
uses a full-width row, image and submit actions share the row below, and the
scrolling project rail retains readable edge padding.

Daemon health is presented as a compact state banner instead of exposing raw
service fields. Healthy state is one line; actionable binary drift becomes a
plain-language warning with Repair; stopped state keeps the relevant CLI
recovery command.

Focused Rails integration and Playwright system coverage pin the banner
contract and prove a 390px status page has no document or control overflow.

The status page also orders projects by active task count, so the busiest
projects appear first in the filter rail, composer selector, and project grid.
Projects with the same count keep their registry order, avoiding unnecessary
movement between live updates. The permanent composer reconciles its project
options after those updates while preserving the operator's current choice.
