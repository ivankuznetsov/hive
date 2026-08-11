# Durable provider-routing incident proof

The AE2-AE8 provider-routing incident matrix now crosses the production
`Attempts::Dispatcher` boundary instead of calling the router with in-memory
attempt maps. It uses v4 attempt records and decision indexes, receipt-bound
health observation, ledger-derived capacity, store reopening across restart,
the shared recovery request lifecycle, and a real `Attempts::Supervisor`
claim/run/terminal transition. Impossible requirement/pin policies fail before
creating an attempt.
