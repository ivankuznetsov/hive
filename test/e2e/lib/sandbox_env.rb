require "bundler"
require "rbconfig"
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
        RBENV_VERSION
        RBENV_DIR
        RBENV_HOOK_PATH
        RBENV_ROOT
        ASDF_DIR
        ASDF_DATA_DIR
        ASDF_RUBY_VERSION
        ASDF_CONFIG_FILE
        CHRUBY_VERSION
        CHRUBY_AUTO
        MISE_RUBY_VERSION
        MISE_DATA_DIR
        GEM_HOME
        GEM_PATH
        GEM_ROOT
      ].freeze

      module_function

      def with(sandbox_dir, run_home, fake_claude_path = Paths.fake_claude)
        Bundler.with_unbundled_env do
          LEAKY_KEYS.each { |key| ENV.delete(key) }
          yield repro_env(sandbox_dir, run_home, fake_claude_path)
        end
      end

      def repro_env(sandbox_dir, run_home, fake_claude_path = Paths.fake_claude)
        # Prepend the directory containing the parent's actual Ruby so that even if
        # rbenv/asdf/chruby/mise shims are still on PATH, the bare `ruby` (and gem
        # shims like `bundle`) resolve to the same interpreter the harness is using.
        ruby_bin_dir = File.dirname(RbConfig.ruby)
        path_parts = [
          ruby_bin_dir,
          File.join(Paths.repo_root, "bin"),
          ENV.fetch("PATH", "")
        ]
        {
          "BUNDLE_GEMFILE" => File.join(sandbox_dir, "Gemfile"),
          "HIVE_HOME" => run_home,
          "HIVE_CLAUDE_BIN" => File.expand_path(fake_claude_path),
          "TERM" => "xterm-256color",
          "PATH" => path_parts.reject(&:empty?).join(":")
        }
      end
    end
  end
end
