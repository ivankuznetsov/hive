---
title: Verify smoke selector and Rake parent isolation
date: 2026-09-09
---

The smoke-isolation regression now pins its nested `TEST` selector to the
provider-free smoke case, preventing an outer focused selector from loading
a unit test with the real-user opt-in. It verifies the environment in the
Rake process that actually launched the smoke child, after the child exits.
The inherited-selector reproduction now passes without changing the
production isolation mechanism.
