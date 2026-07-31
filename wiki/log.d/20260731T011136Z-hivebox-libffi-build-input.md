---
title: Restore the Hivebox Fiddle build dependency
date: 2026-07-31
---

## Hivebox: install libffi headers before bundling

**Action:** Added `libffi-dev` to the Hivebox image's Debian build inputs.
The exact committed Docker build resolved the explicit Fiddle 1.1.8 runtime
gem, but `ruby:3.4-slim` did not provide `ffi.h`; the native extension stopped
the image before Hive or the managed Web app could be installed.

**Coverage:** Added a packaging contract assertion that the libffi headers are
installed before `bundle install`, then rebuilt and smoke-tested the exact
candidate image through the existing random-loopback-port Hivebox proof.
