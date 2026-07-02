# 2026-07-02 — Hive::AtomicFile (arch pass over the pairing PR)

Architecture review of the Telegram pairing PR (#629): the feature adds two
more private copies of the tmp+rename(+fsync) atomic-write pattern, joining
at least five pre-existing ones (`Markers#write_atomic`, `Events`,
`Commands::Init`, `ServiceInstaller::Base#atomic_write`, review
suppression). Introduced `lib/hive/atomic_file.rb` (`Hive::AtomicFile.write`
with `mode:`/`fsync:`) and pointed the two NEW call sites at it
(`PairingStore#write_entries`, `PairingApprovalQueue.write!`). Migrating the
legacy copies is deliberately left as a follow-up — noted in [[gaps]]-style
debt: new state files should use the helper instead of adding another copy.
