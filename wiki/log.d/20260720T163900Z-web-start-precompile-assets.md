# Compile production web assets during startup

- Made production `hive web` guarantee fingerprinted CSS and JavaScript before
  Rails starts: managed bundles compile and validate during provisioning, while
  source checkouts and operator overrides compile at startup using storage
  isolated from the live web databases.
- Made startup fail closed when precompilation does not produce a usable
  Propshaft manifest and application entrypoints, preventing an apparently
  healthy web service from returning 404s for its advertised assets.
- Kept Hivebox's separate image lifecycle unchanged: its image build compiles
  and validates assets once, then marks them precompiled so container startup
  does not repeat the native web preparation step.
- Added command-level regression coverage for successful compilation and for
  unusable compiler output.
