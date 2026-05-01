require "fileutils"
require "json"
require "open3"
require "yaml"
require_relative "cli_driver"
require_relative "path_safety"
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
        @secondary_projects = []
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

      # Scenario YAMLs control `name`; we File.join + rm_rf with it, so a
      # value containing `/`, `..`, or absolute components could escape
      # @run_dir and rm_rf an unrelated tree. Constrain to a single
      # filesystem-safe basename and verify the resolved path is contained
      # within @run_dir before any destructive operation.
      def register_secondary(name)
        name = PathSafety.safe_basename!(name, "register_secondary name")

        path = File.join(@run_dir, name)
        resolved = PathSafety.contained_path!(@run_dir, path, "register_secondary path")
        raise ArgumentError, "register_secondary path #{resolved.inspect} must be directly under #{@run_dir.inspect}" unless File.dirname(resolved) == File.expand_path(@run_dir)

        reject_git_dir!(@sample_project_path)
        FileUtils.rm_rf(path)
        FileUtils.cp_r(@sample_project_path, path)
        initialise_git_repo(path)
        CliDriver.new(path, @run_home).call([ "init" ], cwd: path)
        tune_project_config(path)
        @secondary_projects << path
        path
      end

      def assert_sample_project_unmutated!
        diff_out, diff_err, diff_status = Open3.capture3(
          "git", "-C", Paths.repo_root, "diff", "--quiet", "--", "test/e2e/sample-project"
        )
        unless diff_status.success?
          raise "sample project mutated during e2e run (tracked diff): " \
                "#{diff_err.empty? ? diff_out : diff_err}"
        end

        # `git diff --quiet` ignores untracked files. A scenario that writes
        # a new file under test/e2e/sample-project/ would not be caught by
        # the diff above. Catch those too via porcelain status — any output
        # under that prefix is a mutation.
        status_out, status_err, status_status = Open3.capture3(
          "git", "-C", Paths.repo_root, "status", "--porcelain", "--", "test/e2e/sample-project"
        )
        unless status_status.success?
          raise "sample project mutation guard could not run git status: " \
                "#{status_err.empty? ? status_out : status_err}"
        end
        return if status_out.strip.empty?

        raise "sample project mutated during e2e run (untracked or staged): #{status_out}"
      end

      # Removes all per-scenario state when called: sandbox dir, hive-home,
      # the worktrees tree, and any registered secondary project trees.
      # Caller decides when to invoke it; on `keep_artifacts || failed`
      # Runner skips this so everything under run_dir/scenarios/<name>, plus
      # the per-scenario sandbox/hive_home and any secondary project dirs,
      # is preserved for forensic inspection.
      def cleanup
        worktrees_dir = File.join(@run_dir, "worktrees")
        ([ @sandbox_dir, @run_home, worktrees_dir ] + @secondary_projects).each do |path|
          FileUtils.rm_rf(path)
        rescue Errno::ENOENT
          nil
        end
      end

      def self.cleanup_runs(runs_dir: Paths.runs_dir, retain_days: 7, retain_failed_days: 14, dry_run: false)
        runs_dir = PathSafety.cleanup_root!(runs_dir, default_runs_dir: Paths.default_runs_dir)
        now = Time.now
        deleted = 0
        kept = 0
        deleted_runs = []
        kept_runs = []
        Dir[File.join(runs_dir, "*")].each do |dir|
          next unless File.directory?(dir)

          run_id = File.basename(dir)
          unless PathSafety.generated_run_dir?(run_id)
            kept += 1
            kept_runs << run_record(dir, reason: "name_not_generated_run_id")
            next
          end

          retain = retention_days_for(dir, retain_days: retain_days, retain_failed_days: retain_failed_days)
          if now - File.mtime(dir) < retain.to_i * 86_400
            kept += 1
            kept_runs << run_record(dir, reason: "retained", retain_days: retain)
            next
          end

          FileUtils.rm_rf(dir) unless dry_run
          deleted += 1
          deleted_runs << run_record(dir, reason: dry_run ? "would_delete" : "expired", retain_days: retain)
        end
        { "deleted" => deleted, "kept" => kept, "deleted_runs" => deleted_runs, "kept_runs" => kept_runs }
      end

      # A run that finished cleanly with summary.failed > 0 (some scenarios
      # passed, some failed) earns the longer retention window: forensics
      # for partial failures are just as valuable as for outright crashes.
      # Malformed report.json is treated as failed so we don't lose the
      # evidence to a broken serializer.
      def self.retention_days_for(run_dir, retain_days:, retain_failed_days:)
        report_path = File.join(run_dir, "report.json")
        return retain_failed_days unless File.exist?(report_path)

        report = JSON.parse(File.read(report_path))
        status = report["status"]
        failed = report.dig("summary", "failed").to_i + report.dig("summary", "setup_failed").to_i
        status == "complete" && failed.zero? ? retain_days : retain_failed_days
      rescue JSON::ParserError
        retain_failed_days
      end

      def self.run_record(dir, reason:, retain_days: nil)
        {
          "run_id" => File.basename(dir),
          "path" => dir,
          "reason" => reason,
          "retain_days" => retain_days
        }.compact
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
