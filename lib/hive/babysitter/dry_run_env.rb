require "fileutils"

module Hive
  module Babysitter
    module DryRunEnv
      module_function

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
        ENV["HIVE_BABYSITTER_DRY_RUN_LOG"] = File.join(worktree_path, ".babysitter-dry-run-skipped.log")
        ENV["HIVE_BABYSITTER_REAL_GIT"] = real_git
        ENV["HIVE_BABYSITTER_REAL_GH"] = real_gh
        yield
      ensure
        old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      def prepare_overlay(worktree_path, real_git:, real_gh:)
        overlay = File.join(worktree_path, ".hive-babysitter-dry-run-bin")
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
