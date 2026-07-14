require "fileutils"
require "rbconfig"
require "shellwords"
require "tmpdir"

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

      def with_env(worktree_path)
        # Resolve real git/gh *before* prepending the overlay onto PATH,
        # otherwise `which` finds the overlay wrappers and the stubs `exec`
        # themselves recursively until the babysitter timeout.
        real_git = which("git").to_s
        real_gh = which("gh").to_s
        skip_log = File.join(worktree_path, SKIP_LOG_BASENAME)
        gh_auth_config_dir = materialize_gh_auth_config(gh_config_dir)
        overlay = prepare_overlay(
          worktree_path,
          real_git: real_git,
          real_gh: real_gh,
          gh_config_dir: gh_auth_config_dir,
          skip_log: skip_log
        )
        old = {
          "PATH" => ENV["PATH"],
          "HIVE_BABYSITTER_DRY_RUN_LOG" => ENV["HIVE_BABYSITTER_DRY_RUN_LOG"],
          "HIVE_BABYSITTER_REAL_GIT" => ENV["HIVE_BABYSITTER_REAL_GIT"],
          "HIVE_BABYSITTER_REAL_GH" => ENV["HIVE_BABYSITTER_REAL_GH"]
        }
        ENV["PATH"] = [ overlay, ENV["PATH"] ].compact.join(File::PATH_SEPARATOR)
        ENV["HIVE_BABYSITTER_DRY_RUN_LOG"] = skip_log
        ENV["HIVE_BABYSITTER_REAL_GIT"] = real_git
        ENV["HIVE_BABYSITTER_REAL_GH"] = real_gh
        yield
      ensure
        old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        FileUtils.rm_rf(File.join(worktree_path, OVERLAY_DIRNAME))
        FileUtils.rm_rf(gh_auth_config_dir) if gh_auth_config_dir
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

      def materialize_gh_auth_config(source_dir)
        auth_dir = Dir.mktmpdir("hive-babysitter-gh-auth")
        return auth_dir if source_dir.to_s.empty?

        source_root = File.realpath(File.expand_path(source_dir))
        return auth_dir unless trusted_config_entry?(File.stat(source_root), :directory?)

        source_path = File.realpath(File.join(source_root, "hosts.yml"))
        File.open(source_path, File::RDONLY | File::NOFOLLOW) do |source|
          return auth_dir unless trusted_config_entry?(source.stat, :file?)

          destination = File.join(auth_dir, "hosts.yml")
          File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |target|
            IO.copy_stream(source, target)
          end
        end
        auth_dir
      rescue SystemCallError, IOError
        FileUtils.rm_f(File.join(auth_dir, "hosts.yml")) if auth_dir
        auth_dir
      end

      def trusted_config_entry?(stat, type)
        stat.public_send(type) && stat.uid == Process.uid && (stat.mode & 0o022).zero?
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
