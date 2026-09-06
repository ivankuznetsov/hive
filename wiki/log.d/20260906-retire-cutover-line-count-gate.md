---
title: Retire the one-time cutover line-count gate
date: 2026-09-06
---

The SQLite simplification inventory remains historical evidence, not an exact
line-count budget for all future code. Removed the test that compared current
production line counts to frozen totals and its Git-history helpers. Behavioral
bootstrap, retired-store/schema/constant, and operator-documentation regression
checks remain active. CI exposed this obsolete constraint when the hourly
provider retry fix changed the unrelated production count by ten lines.
