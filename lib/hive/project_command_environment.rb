module Hive
  # Environment overrides for commands Hive runs on behalf of a *project*
  # (review CI, council commands) inside a task worktree.
  #
  # Hive's own processes carry a private Ruby load path: the detached attempt
  # launcher re-enters Hive with RUBYLIB set to the controller's resolved
  # $LOAD_PATH (Hive's lib, agent-cli-runtime, and every activated gem), and
  # attempt workers inherit it. A Ruby project that requires its own pinned
  # `hive` gem would otherwise load the running Hive deployment instead.
  # Unsetting the toolchain keys lets the project's `ruby`/`bundle` resolve
  # exactly as they would from the operator's shell. Hive's own child `hive`
  # invocations stay self-sufficient: bin/hive puts its lib and bundled
  # components on $LOAD_PATH itself and resolves gems through RubyGems.
  module ProjectCommandEnvironment
    TOOLCHAIN_KEYS = %w[
      RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS GEM_HOME GEM_PATH
      BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION
    ].freeze

    module_function

    def overrides(environment = ENV)
      keys = TOOLCHAIN_KEYS + environment.keys.grep(/\ABUNDLER_ORIG_/)
      keys.to_h { |key| [ key, nil ] }
    end
  end
end
