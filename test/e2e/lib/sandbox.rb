require "fileutils"
require "json"
require "open3"
require "yaml"
require_relative "cli_driver"
require_relative "paths"

module Hive
  module E2E
    class Sandbox
      attr_reader :run_dir, :sandbox_dir, :run_home

      def self.bootstrap(run_dir, sample_project_path: Paths.sample_project)
        new(run_dir, sample_project_path: sample_project_path).bootstrap
      end

      def initialize(run_dir, sample_project_path: Paths.sample_project)
        @run_dir = run_dir
        @sample_project_path = sample_project_path
        @sandbox_dir = File.join(run_dir, "sandbox")
        @run_home = File.join(run_dir, "hive-home")
      end

      def bootstrap
        reject_git_dir!(@sample_project_path)
        FileUtils.mkdir_p(@run_dir)
        FileUtils.rm_rf(@sandbox_dir)
        FileUtils.rm_rf(@run_home)
        FileUtils.cp_r(@sample_project_path, @sandbox_dir)
        initialise_git_repo(@sandbox_dir)
        FileUtils.mkdir_p(@run_home)
        File.write(File.join(@run_home, "config.yml"), { "registered_projects" => [] }.to_yaml)
        CliDriver.new(@sandbox_dir, @run_home).call([ "init" ], cwd: @sandbox_dir)
        tune_project_config(@sandbox_dir)
        self
      rescue StandardError
        FileUtils.rm_rf(@sandbox_dir)
        FileUtils.rm_rf(@run_home)
        raise
      end

      def register_secondary(name)
        path = File.join(@run_dir, name)
        reject_git_dir!(@sample_project_path)
        FileUtils.rm_rf(path)
        FileUtils.cp_r(@sample_project_path, path)
        initialise_git_repo(path)
        CliDriver.new(path, @run_home).call([ "init" ], cwd: path)
        tune_project_config(path)
        path
      end

      def assert_sample_project_unmutated!
        out, err, status = Open3.capture3("git", "-C", Paths.repo_root, "diff", "--quiet", "--", "test/e2e/sample-project")
        return if status.success?

        raise "sample project mutated during e2e run: #{err.empty? ? out : err}"
      end

      # Removes all per-scenario state when called: sandbox dir, hive-home, and
      # the worktrees tree. Caller decides when to invoke it; on
      # `keep_artifacts || failed` Runner skips this so everything under
      # run_dir/scenarios/<name>, plus the per-scenario sandbox/hive_home, is
      # preserved for forensic inspection.
      def cleanup
        worktrees_dir = File.join(@run_dir, "worktrees")
        [ @sandbox_dir, @run_home, worktrees_dir ].each do |path|
          FileUtils.rm_rf(path)
        rescue Errno::ENOENT
          nil
        end
      end

      def self.cleanup_runs(runs_dir: Paths.runs_dir, retain_days: 7, retain_failed_days: 14)
        now = Time.now
        deleted = 0
        kept = 0
        Dir[File.join(runs_dir, "*")].each do |dir|
          next unless File.directory?(dir)

          report_path = File.join(dir, "report.json")
          status = File.exist?(report_path) ? JSON.parse(File.read(report_path))["status"] : "crashed"
          retain = status == "complete" ? retain_days : retain_failed_days
          if now - File.mtime(dir) < retain.to_i * 86_400
            kept += 1
            next
          end

          FileUtils.rm_rf(dir)
          deleted += 1
        end
        { "deleted" => deleted, "kept" => kept }
      end

      private

      def reject_git_dir!(path)
        return unless File.exist?(File.join(path, ".git"))

        raise "sample project must not contain .git: #{path}"
      end

      def initialise_git_repo(path)
        run!("git", "-C", path, "init", "-b", "master", "--quiet")
        run!("git", "-C", path, "config", "user.email", "test@example.com")
        run!("git", "-C", path, "config", "user.name", "Hive E2E")
        run!("git", "-C", path, "config", "commit.gpgsign", "false")
        run!("git", "-C", path, "add", "-A")
        run!("git", "-C", path, "commit", "-m", "initial", "--quiet")
      end

      def tune_project_config(path)
        cfg_path = File.join(path, ".hive-state", "config.yml")
        cfg = YAML.safe_load(File.read(cfg_path)) || {}
        cfg["worktree_root"] = File.join(@run_dir, "worktrees")
        cfg["review"] ||= {}
        cfg["review"]["ci"] ||= {}
        cfg["review"]["ci"]["command"] = nil
        cfg["review"]["reviewers"] = []
        cfg["review"]["browser_test"] ||= {}
        cfg["review"]["browser_test"]["enabled"] = false
        cfg["review"]["triage"] ||= {}
        cfg["review"]["triage"]["enabled"] = false
        File.write(cfg_path, cfg.to_yaml)
      end

      def run!(*cmd)
        out, err, status = Open3.capture3(*cmd)
        raise "command failed: #{cmd.join(' ')}\n#{err.empty? ? out : err}" unless status.success?

        out
      end
    end
  end
end
