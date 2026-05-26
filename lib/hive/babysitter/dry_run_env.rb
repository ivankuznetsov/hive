require "fileutils"

module Hive
  module Babysitter
    module DryRunEnv
      module_function

      def with_env(worktree_path)
        overlay = prepare_overlay(worktree_path)
        old = {
          "PATH" => ENV["PATH"],
          "HIVE_BABYSITTER_DRY_RUN_LOG" => ENV["HIVE_BABYSITTER_DRY_RUN_LOG"],
          "HIVE_BABYSITTER_REAL_GIT" => ENV["HIVE_BABYSITTER_REAL_GIT"],
          "HIVE_BABYSITTER_REAL_GH" => ENV["HIVE_BABYSITTER_REAL_GH"]
        }
        ENV["PATH"] = [ overlay, ENV["PATH"] ].compact.join(File::PATH_SEPARATOR)
        ENV["HIVE_BABYSITTER_DRY_RUN_LOG"] = File.join(worktree_path, ".babysitter-dry-run-skipped.log")
        ENV["HIVE_BABYSITTER_REAL_GIT"] = which("git").to_s
        ENV["HIVE_BABYSITTER_REAL_GH"] = which("gh").to_s
        yield
      ensure
        old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      def prepare_overlay(worktree_path)
        overlay = File.join(worktree_path, ".hive-babysitter-dry-run-bin")
        FileUtils.mkdir_p(overlay)
        root = File.expand_path("../../..", __dir__)
        {
          "git" => File.join(root, "bin", "hive-babysitter-stub-git"),
          "gh" => File.join(root, "bin", "hive-babysitter-stub-gh")
        }.each do |name, target|
          link = File.join(overlay, name)
          FileUtils.rm_f(link)
          File.symlink(target, link)
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
