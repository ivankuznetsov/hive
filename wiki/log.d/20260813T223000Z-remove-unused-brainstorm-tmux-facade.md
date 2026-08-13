## Remove unused Brainstorm tmux facade

- Removed the uncalled `Stages::BrainstormTmux` compatibility facade. The live
  brainstorm stage already invokes `ClaudeLauncher` through
  `Stages::Brainstorm#run_claude!`.
- Retargeted the facade's meaningful preflight, sentinel, cleanup, collision,
  and real-tmux tests to the live launcher and brainstorm entrypoints; removed
  only duplicate forwarding assertions.
