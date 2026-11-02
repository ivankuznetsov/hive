# Enforce direct benchmark credential declarations (U2)

Ported canonical hive-bench a09fd65: direct gen accepts one supported API
variable or one exclusive regular OAuth file, refusing invalid declarations
with exit 70 before Docker. Gate ignores generator controls. Optional Docker
arrays use Bash 3.2 nounset guards; IsolationError retains phase/status and
omits untrusted stderr. Default-suite tests exercise real Ruby/shell execution
with decoy-only fake Docker, argv boundaries and exact refusal diagnostics.
