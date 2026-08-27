# Refresh the installed OpenCode offline-smoke route

**Action:** Changed the installed-CLI offline smoke default from the retired
`opencode/deepseek-v4-flash-free` inventory entry to the current
`opencode/hy3-free` route. The replacement exposes the same `high` reasoning
variant required by the smoke and keeps the test read-only: its guarded wrapper
still permits only version, help, auth-list, and model-inventory commands.
