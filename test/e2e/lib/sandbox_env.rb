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

      # Stringify an env-overrides hash: keys to strings, values to strings
      # except nil (which Process.spawn / Open3 treat as "unset this var").
      def stringify_env(env)
        env.each_with_object({}) { |(key, value), out| out[key.to_s] = value.nil? ? nil : value.to_s }
      end

      # Merge scenario overrides while preserving the two hermetic-gh keys.
      # A caller may still replace PATH for a fixture, but the default-deny
      # shim remains its first entry and the run-local script root cannot be
      # redirected to a host-controlled location.
      def merge(base, overrides)
        merged = base.merge(stringify_env(overrides))
        merged["PATH"] = prepend_gh_shim(merged["PATH"])
        merged["HIVE_E2E_GH_STUB_DIR"] = base.fetch("HIVE_E2E_GH_STUB_DIR")
        merged
      end

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
          Paths.fixtures_dir,
          ruby_bin_dir,
          File.join(Paths.repo_root, "bin"),
          ENV.fetch("PATH", "")
        ]
        {
          "BUNDLE_GEMFILE" => File.join(sandbox_dir, "Gemfile"),
          "HIVE_HOME" => run_home,
          "HIVE_CLAUDE_BIN" => File.expand_path(fake_claude_path),
          "HIVE_CODEX_BIN" => File.expand_path(fake_claude_path),
          "HIVE_E2E_GH_STUB_DIR" => File.join(run_home, "gh-stub"),
          "TERM" => "xterm-256color",
          "PATH" => path_parts.reject(&:empty?).join(":")
        }
      end

      def prepend_gh_shim(path)
        fixture_path = File.expand_path(Paths.fixtures_dir)
        remaining = path.to_s.split(":").reject(&:empty?).reject do |part|
          File.expand_path(part) == fixture_path
        end
        ([ Paths.fixtures_dir ] + remaining).join(":")
      end
    end
  end
end
