---
date: 2026-09-06
slug: refresh-terminal-publication-proof
---

- Terminal attempt publication now rereads the hot row after same-tick delivery
  acknowledgements before promoting its immutable proof. This avoids treating
  the expected acknowledgement update as a receipt-integrity conflict and
  prevents an unnecessary daemon poll before provider-route recovery.
