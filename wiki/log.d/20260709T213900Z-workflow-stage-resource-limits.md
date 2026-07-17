# Workflow descriptors accept stage resource limits

Project-authored agent and council stages can now set `budget_usd` and
`timeout_sec` directly in their workflow descriptors. The descriptor parser
validates both values and passes them to the existing generic stage runners as
defaults that explicitly authored project stage configuration can override.
Merged built-in defaults no longer shadow descriptor values. Council command
reviewers/revisers now honor the same timeout with process-group termination,
and profiles without native budget support write an explicit warning instead
of silently dropping the cap.

Terminal stages continue to reject active-runner fields, including these new
resource limits.
