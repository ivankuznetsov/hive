# Workflow descriptors accept stage resource limits

Project-authored agent and council stages can now set `budget_usd` and
`timeout_sec` directly in their workflow descriptors. The descriptor parser
validates both values and passes them to the existing generic stage runners as
defaults that project stage configuration can override.

Terminal stages continue to reject active-runner fields, including these new
resource limits.
