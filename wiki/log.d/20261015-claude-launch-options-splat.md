# 2026-10-15 — Claude launch keywords stated once

- `Stages::Base.spawn_claude!` and `Hive::ClaudeLauncher.launch!` no longer
  restate the ~16 optional launch keywords. Each names only what it reads or
  re-defaults (`cwd`, `profile`, MCP config, `implementation_stage`; and in
  `launch!` the required task/prompt/budget keys) and takes the rest as
  `**options`, validated and defaulted by
  `ClaudeLauncher.launch_options` against `ClaudeLauncher::LAUNCH_OPTIONS`.
  An unknown keyword still raises `ArgumentError` with Ruby's own message
  shape, so the splat cannot reach `spawn_agent`'s wider keywords
  (`cfg:`, `cli_flags:`, `receipt_model:`). Behaviour is unchanged: the
  explicit-routing non-Claude branch still drops MCP flags and passes
  `cfg`/`implementation_stage`; the launcher path still does neither.
