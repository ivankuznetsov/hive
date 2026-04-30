require "bundler"
require_relative "paths"

module Hive
  module E2E
    module SandboxEnv
      LEAKY_KEYS = %w[
        BUNDLE_BIN_PATH
        BUNDLE_GEMFILE
        BUNDLE_PATH
        BUNDLE_APP_CONFIG
        BUNDLER_VERSION
        RUBYOPT
        RUBYLIB
      ].freeze

      module_function

      def with(sandbox_dir, run_home, fake_claude_path = Paths.fake_claude)
        Bundler.with_unbundled_env do
          LEAKY_KEYS.each { |key| ENV.delete(key) }
          yield repro_env(sandbox_dir, run_home, fake_claude_path)
        end
      end

      def repro_env(sandbox_dir, run_home, fake_claude_path = Paths.fake_claude)
        {
          "BUNDLE_GEMFILE" => File.join(sandbox_dir, "Gemfile"),
          "HIVE_HOME" => run_home,
          "HIVE_CLAUDE_BIN" => File.expand_path(fake_claude_path),
          "TERM" => "xterm-256color",
          "PATH" => [ File.join(Paths.repo_root, "bin"), ENV.fetch("PATH", "") ].join(":")
        }
      end
    end
  end
end
