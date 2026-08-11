## Named Pi bindings isolate subscription identity

Named launch bindings now clear the selected adapter profile's recognized
ambient credential variables before preflight and launch. The inventory lives
in the extracted `agent-cli-runtime` compatibility profiles and is
parity-tested against Hive's temporary internal copies instead of being
hard-coded in provider routing. For Pi, this keeps the selected
`PI_CODING_AGENT_DIR` subscription/session authoritative for the symbolic
account while leaving the default binding's ambient environment unchanged.
