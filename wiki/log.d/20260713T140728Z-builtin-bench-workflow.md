# Built-in benchmark workflow

- Registered `bench` as a built-in workflow with the native
  `inbox -> extract -> generate -> judge -> publish -> done` stage sequence.
- Packaged the hive-bench stage instructions in the gem so
  `hive init . --workflow bench` needs no project-local descriptor or prompt
  copies.
- Added descriptor, packaging, registry, and init/new integration coverage.
- Documented the named workflow setup and reserved built-in id.
