# Keep package security scans at admission boundaries

Installed workflow reads now retain manifest/inventory integrity and runtime
validation without repeating package security scans. Incoming package placement,
registry validation and publication retain full scanning by default.

The real-project status profile before this change took 103.2 seconds with 254
Betterleaks launches. The first fixed profile took 16.4 seconds with two launches
outside installed-package validation (20 projects, 366 rows in both profiles).
These are local observations, not timing guarantees. Regression tests require
scanner-free installed reads, continued tamper rejection, and fail-closed
installation when the scanner cannot run.
