---
date: 2026-09-09
slug: sandbox-test-ruby-portability
---

- The real managed evidence-server sandbox test now launches with the running
  Ruby interpreter. Hosted Ruby setup need not provide `/usr/bin/ruby`; the
  sandbox already mounts the selected runtime prefix.
