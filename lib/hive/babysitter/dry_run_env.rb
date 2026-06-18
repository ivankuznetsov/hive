require "fileutils"

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

      def with_env(worktree_path)
        # Resolve real git/gh *before* prepending the overlay onto PATH,
        # otherwise `which` finds the overlay wrappers and the stubs `exec`
        # themselves recursively until the babysitter timeout.
        real_git = which("git").to_s
        real_gh = which("gh").to_s
        overlay = prepare_overlay(worktree_path, real_git: real_git, real_gh: real_gh)
        old = {
          "PATH" => ENV["PATH"],
          "HIVE_BABYSITTER_DRY_RUN_LOG" => ENV["HIVE_BABYSITTER_DRY_RUN_LOG"],
          "HIVE_BABYSITTER_REAL_GIT" => ENV["HIVE_BABYSITTER_REAL_GIT"],
          "HIVE_BABYSITTER_REAL_GH" => ENV["HIVE_BABYSITTER_REAL_GH"]
        }
        ENV["PATH"] = [ overlay, ENV["PATH"] ].compact.join(File::PATH_SEPARATOR)
        ENV["HIVE_BABYSITTER_DRY_RUN_LOG"] = File.join(worktree_path, SKIP_LOG_BASENAME)
        ENV["HIVE_BABYSITTER_REAL_GIT"] = real_git
        ENV["HIVE_BABYSITTER_REAL_GH"] = real_gh
        yield
      ensure
        old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        FileUtils.rm_rf(File.join(worktree_path, OVERLAY_DIRNAME))
      end

      def prepare_overlay(worktree_path, real_git:, real_gh:)
        overlay = File.join(worktree_path, OVERLAY_DIRNAME)
        FileUtils.mkdir_p(overlay)
        root = File.expand_path("../../..", __dir__)
        {
          "git" => [ File.join(root, "bin", "hive-babysitter-stub-git"), "HIVE_BABYSITTER_REAL_GIT", real_git ],
          "gh" => [ File.join(root, "bin", "hive-babysitter-stub-gh"), "HIVE_BABYSITTER_REAL_GH", real_gh ]
        }.each do |name, (target, env_name, real_path)|
          link = File.join(overlay, name)
          FileUtils.rm_f(link)
          File.write(link, <<~RUBY)
            #!/usr/bin/env ruby
            ENV[#{env_name.dump}] = #{real_path.to_s.dump}
            exec(#{target.dump}, *ARGV)
          RUBY
          FileUtils.chmod("+x", link)
        end
        overlay
      end

      def which(name)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
          candidate = File.join(dir, name)
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
        nil
      end
    end
  end
end
