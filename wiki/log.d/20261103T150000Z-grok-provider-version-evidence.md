## Validate official Grok version ownership

Corrected the Grok recognizer to xAI's published npm package rather than a
third-party CLI with the same executable name. Added exact-linked native
versioned installation evidence backed by the provider's npm installer metadata.
The dynamic Node bootstrap stays opaque and cannot seed a concrete-target
version cache. Positive/negative filesystem fixtures and advisory comparisons
passed without invoking a real provider.
