---
title: Synchronize project-rail submission proof with durable state
date: 2026-11-03
tags: [web, testing, ci]
pages: [testing]
---

The project-rail browser test now waits for the submitted task's live row and
cleared composer, then verifies its preserved attachment on disk. Waiting for
the row reproduced the CI failure in the old flash assertion: a subsequent
status GET removes the redirect's one-request notice. Dedicated composer tests
continue to check the notice; the filtering scenario checks durable submission
outcomes without depending on the banner's lifetime.
