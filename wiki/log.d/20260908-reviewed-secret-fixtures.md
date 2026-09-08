## Avoid blocking publication on reviewed synthetic test credentials

Betterleaks now filters the exact dummy password and token values observed in
Todero controller tests and Hive brainstorm-suggestion security tests, scoped
to their exact test paths. No rule or test directory is disabled. The scanner
policy version changes with this policy; task-authored suppressions stay ignored.
Real-binary regression checks cover text and Git scans, other token values in
the same paths, and the approved dummy values outside those paths.
