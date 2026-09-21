# Config defaults validation rejects altered marker candidates

The `Config::DEFAULTS` documentation renderer now rejects marker-like begin or
end comments anywhere in the page unless they are the single exact managed
pair. This closes the case where an exact current region plus a colon-less,
altered pair could survive rendering unchanged and false-pass the read-only
drift guard. Focused tests cover altered pairs before and after the exact region
for pure rendering, read-only verification, and regeneration before any write.
