---
title: Provider routing entrypoint exposes PolicyStore
date: 2026-08-11T16:45:00Z
tags: [provider-routing, components, entrypoint]
---

Added `ProviderRouting::PolicyStore` to the public provider-routing autoload
surface. A clean `require "hive/provider_routing"` can now resolve every
catalogued public constant without an incidental Attempts require.
