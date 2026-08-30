# 2026-08-30 — Close new-idea review gaps

Derived TUI snapshots now retain the registry projects behind their shared
new-idea admission, keeping numeric-entry and exact-name resolution consistent
with that registry-wide authority. A scoped blank identity fails closed as an
invalid scope instead of degrading to generic selection feedback.

Blocked submissions keep their typed reason visible in the project picker after
the transient flash expires, including a `draft kept` affordance when composed
work remains. Picker copy also fails loudly for impossible admission states,
documents directional nil-cursor movement, and treats `invalid_scope` as an
entry-only result.
