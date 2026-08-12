---
title: Recover pinned historical workflow stages through durable dispatch
type: change
created: 2026-08-12
---

Recovery now classifies a managed task's retry verb from its immutable pinned
workflow descriptor. Durable request dispatch resolves the request through its
stored canonical task folder, revalidates project and stage identity, and only
then substitutes that folder into the worker command. Historical Honeycomb
stages therefore keep using the universal recovery lifecycle after the
installed package advances to a different stage topology.
