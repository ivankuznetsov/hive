---
title: Review grant CI coverage and web dependency patches
date: 2026-11-02
---

Added focused regressions for invalid completion escalation proofs, changed
HEAD or dirty worktree refusal before guardrail recovery, and standalone
reads of later escalation answers. These cover the three lines missed by
the review grant CI coverage gate without changing runtime behavior.

Updated the web lockfile to Nokogiri 1.19.6, Loofah 2.25.3, and
rails-html-sanitizer 1.7.2 to resolve the HTML parser/sanitizer audit failures.
