# 2026-08-31 — Keep detached supervisor startup outside caller Bundler state

The private detached-attempt supervisor route now dispatches before public CLI
loading, and its launcher clears inherited Ruby/Bundler toolchain variables.
The wrapper can therefore claim through its inherited descriptors without a
caller bundle or temporary HOME preventing startup.

See [[modules/attempts]] and [[testing]].
