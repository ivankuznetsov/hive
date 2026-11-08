# Config defaults validation rejects multiline marker candidates

The `Config::DEFAULTS` documentation renderer now detects marker-like HTML
comments even when their marker text wraps across lines. Wrapped begin or end
candidates before or after the exact managed region therefore fail closed in
pure rendering, read-only drift verification, and regeneration before writes.
