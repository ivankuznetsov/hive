require "fileutils"
require "rbconfig"
require "shellwords"

module Hive
  module Babysitter
    module DryRunEnv
      module_function

      # The overlay-bin shims and skip log live at the worktree root. Both are
      # transient and gitignored (see the repo `.gitignore`) so a stage-exit
      # CleanExit never flags them as out-of-scope residue. The overlay dir is
      # pure tooling — no caller reads it after the block — so we remove it on
      # exit to keep the worktree pristine even in repos lacking the gitignore
      # entry. The skip log is deliberately left in place: it is the dry-run's
      # diagnostic record and callers/tests read it after `with_env` returns.
      OVERLAY_DIRNAME = ".hive-babysitter-dry-run-bin"
      SKIP_LOG_BASENAME = ".babysitter-dry-run-skipped.log"
      RUBY_STARTUP_ENV = %w[
        RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH GEM_HOME GEM_PATH
      ].freeze
      DYNAMIC_LOADER_ENV_PATTERN = /\A(?:LD|DYLD)_/
      DYNAMIC_LOADER_STARTUP_ENV = %w[
        LD_AUDIT LD_LIBRARY_PATH LD_PRELOAD
        DYLD_FALLBACK_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH DYLD_FRAMEWORK_PATH
        DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_VERSIONED_FRAMEWORK_PATH DYLD_VERSIONED_LIBRARY_PATH
      ].freeze

      def with_env(worktree_path)
        old = {
          "PATH" => ENV["PATH"],
          "HIVE_BABYSITTER_DRY_RUN_LOG" => ENV["HIVE_BABYSITTER_DRY_RUN_LOG"],
          "HIVE_BABYSITTER_REAL_GIT" => ENV["HIVE_BABYSITTER_REAL_GIT"],
          "HIVE_BABYSITTER_REAL_GH" => ENV["HIVE_BABYSITTER_REAL_GH"]
        }.merge(ENV.to_h.select { |key, _value| DYNAMIC_LOADER_ENV_PATTERN.match?(key) })
        clear_dynamic_loader_env
        # Resolve real git/gh *before* prepending the overlay onto PATH,
        # otherwise `which` finds the overlay wrappers and the stubs `exec`
        # themselves recursively until the babysitter timeout.
        real_git = which("git").to_s
        real_gh = which("gh").to_s
        skip_log = File.join(worktree_path, SKIP_LOG_BASENAME)
        overlay = prepare_overlay(
          worktree_path,
          real_git: real_git,
          real_gh: real_gh,
          gh_config_dir: gh_config_dir,
          skip_log: skip_log
        )
        ENV["PATH"] = [ overlay, ENV["PATH"] ].compact.join(File::PATH_SEPARATOR)
        ENV["HIVE_BABYSITTER_DRY_RUN_LOG"] = skip_log
        ENV["HIVE_BABYSITTER_REAL_GIT"] = real_git
        ENV["HIVE_BABYSITTER_REAL_GH"] = real_gh
        yield
      ensure
        clear_dynamic_loader_env
        old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        FileUtils.rm_rf(File.join(worktree_path, OVERLAY_DIRNAME))
      end

      def prepare_overlay(worktree_path, real_git:, real_gh:, gh_config_dir: nil, skip_log:)
        overlay = File.join(worktree_path, OVERLAY_DIRNAME)
        FileUtils.mkdir_p(overlay)
        root = File.expand_path("../../..", __dir__)
        {
          "git" => [
            File.join(root, "bin", "hive-babysitter-stub-git"),
            {
              "HIVE_BABYSITTER_REAL_GIT" => real_git,
              "HIVE_BABYSITTER_DRY_RUN_LOG" => skip_log
            }
          ],
          "gh" => [
            File.join(root, "bin", "hive-babysitter-stub-gh"),
            {
              "HIVE_BABYSITTER_REAL_GH" => real_gh,
              "HIVE_BABYSITTER_DRY_RUN_LOG" => skip_log,
              "HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR" => gh_config_dir
            }
          ]
        }.each do |name, (target, env)|
          link = File.join(overlay, name)
          FileUtils.rm_f(link)
          env_setup = env.map { |env_name, value| shell_env_assignment(env_name, value) }.join("\n")
          # Start the overlay through /bin/sh, not Ruby: Ruby consumes RUBYOPT/RUBYLIB
          # before script code runs, so a Ruby shim cannot scrub those variables in time.
          # The shell wrapper clears Ruby/Bundler/Gem startup env, pins the handoff env, and
          # then invokes the shared Ruby stub through the running Ruby's absolute path.
          File.write(link, <<~SH)
            #!/bin/sh
            unset #{RUBY_STARTUP_ENV.join(' ')}
            unset #{DYNAMIC_LOADER_STARTUP_ENV.join(' ')}
            #{env_setup}
            exec #{shell_word(RbConfig.ruby)} #{shell_word(target)} "$@"
          SH
          FileUtils.chmod("+x", link)
        end
        overlay
      end

      def shell_env_assignment(name, value)
        value.nil? ? "unset #{name}" : "export #{name}=#{shell_word(value)}"
      end

      def clear_dynamic_loader_env
        ENV.keys.grep(DYNAMIC_LOADER_ENV_PATTERN).each { |key| ENV.delete(key) }
      end

      def shell_word(value)
        Shellwords.escape(value.to_s)
      end

      def gh_config_dir
        gh_config = ENV["GH_CONFIG_DIR"].to_s
        return gh_config unless gh_config.empty?

        xdg_config = ENV["XDG_CONFIG_HOME"].to_s
        return File.join(xdg_config, "gh") unless xdg_config.empty?

        home = ENV["HOME"].to_s
        return if home.empty?

        File.join(home, ".config", "gh")
      end

      def which(name)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return File.realpath(candidate) if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end
    end
  end
end
