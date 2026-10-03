# Benchmark provider routing and mixed-harness usage fixes

The packaged runner mounts the default Pi OpenRouter catalog only when a Pi
route uses OpenRouter. Native-provider Pi profiles no longer acquire an unrelated
OpenRouter credential requirement, including in mixed OpenCode campaigns.
Explicit custom catalogs and historical OpenRouter Pi profiles remain supported.

OpenCode's latest cumulative usage receipt now adds to stream usage from other
harnesses rather than overwriting it when the model IDs coincide. Regression
tests reproduced both failures before the fixes. These are local harness changes;
live campaign execution and deployment are not established by these tests.
