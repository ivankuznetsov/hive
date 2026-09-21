# Active consumer repair during PR sweep

The in-process daemon and operational status fallback now request active rows.
The bot CLI graph retains ordinary rows pending an explicit terminal notification
recovery decision. Exact task lookup and explicit archive reads remain available.
Removed unused TUI archive-cache composition helpers after separating producers.
Status stage fallback uses the canonical active-stage list, which includes
non-inert terminal stages; archive membership survives action annotation.
