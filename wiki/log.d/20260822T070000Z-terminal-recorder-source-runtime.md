# Terminal evidence resolves source-loaded agent runtime

**Problem:** Managed terminal evidence assumed `agent-cli-runtime` was an
activated RubyGem and fetched its load path through `Gem.loaded_specs`. Hive's
local dogfood daemon instead loads the monorepo component through `RUBYLIB`, so
the runtime was present in `$LOADED_FEATURES` but absent from the gem registry.
Every terminal claim failed before its custody worker could start.

**Change:** `TerminalRecorder` now prefers the activated gem's require paths and
falls back to the directory of the already-loaded `agent_cli_runtime.rb`
feature. The worker therefore receives the same dependency path under packaged
and source-checkout launches without inheriting the controller's complete
`RUBYLIB` or other Ruby injection variables.

**Verification:** The terminal recorder unit tests cover both an activated gem
and a source-loaded component with the gem deliberately removed from the
registry.
