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
        BUNDLER_SETUP
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
        GH_HOST
        GH_REPO
      ].freeze

      PROTECTED_ENV_KEYS = %w[
        BUNDLE_GEMFILE
        HIVE_HOME
        HIVE_CLAUDE_BIN
        HIVE_CODEX_BIN
        HIVE_GROK_BIN
        HIVE_PI_BIN
        HIVE_BIN
        HIVE_INVOKED_BIN
        HIVE_GH_BIN
        HIVE_E2E_GH_STUB_DIR
        RUBYLIB
      ].freeze

      module_function

      # Stringify an env-overrides hash: keys to strings, values to strings
      # except nil (which Process.spawn / Open3 treat as "unset this var").
      def stringify_env(env)
        env.each_with_object({}) { |(key, value), out| out[key.to_s] = value.nil? ? nil : value.to_s }
      end

      # Merge scenario overrides while preserving the harness-owned isolation,
      # executable, agent-fixture, and GitHub-shim keys.
      # A caller may still replace PATH for a fixture, but the default-deny
      # shim remains its first entry and the run-local script root cannot be
      # redirected to a host-controlled location.
      def merge(base, overrides)
        merged = base.merge(stringify_env(overrides))
        merged["PATH"] = prepend_gh_shim(merged["PATH"])
        PROTECTED_ENV_KEYS.each { |key| merged[key] = base.fetch(key) }
        merged
      end

      def with(sandbox_dir, run_home, fake_claude_path = Paths.fake_claude)
        ruby_lib = bundle_require_path
        Bundler.with_unbundled_env do
          LEAKY_KEYS.each { |key| ENV.delete(key) }
          yield repro_env(sandbox_dir, run_home, fake_claude_path, ruby_lib: ruby_lib)
        end
      end

      def repro_env(sandbox_dir, run_home, fake_claude_path = Paths.fake_claude,
                    ruby_lib: bundle_require_path)
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
          "HIVE_GROK_BIN" => File.expand_path(fake_claude_path),
          "HIVE_PI_BIN" => File.expand_path(fake_claude_path),
          "HIVE_BIN" => Paths.hive_bin,
          "HIVE_INVOKED_BIN" => Paths.hive_bin,
          "HIVE_GH_BIN" => Paths.gh_shim,
          "HIVE_E2E_GH_STUB_DIR" => File.join(run_home, "gh-stub"),
          "RUBYLIB" => ruby_lib,
          "TERM" => "xterm-256color",
          "PATH" => path_parts.reject(&:empty?).join(":")
        }
      end

      def bundle_require_path
        Bundler.load.specs.flat_map(&:full_require_paths).uniq.join(File::PATH_SEPARATOR)
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
