require "open3"
require "securerandom"
require "hive/agent"
require "hive/agent_profiles"
require "hive/git_ops"
require "hive/patrol/fingerprint"
require "hive/patrol/runner_task"
require "hive/patrol/state_store"
require "hive/patrol/validator"
require "hive/stages/base"
require "hive/usage_db"
require "hive/worktree"

module Hive
  module Patrol
    class Fixer
      PatchAttempt = Struct.new(:id, :finding, :branch, :worktree_path, :validation,
                                :passed, :diffstat, :head_sha, keyword_init: true) do
        def to_h
          {
            "id" => id,
            "finding_id" => finding.id,
            "fingerprint" => finding.fingerprint,
            "branch" => branch,
            "worktree_path" => worktree_path,
            "validation" => validation,
            "passed" => passed,
            "diffstat" => diffstat,
            "head_sha" => head_sha
          }
        end
      end

      TemplateBindings = Struct.new(
        :project_root, :finding, :output_path, :user_supplied_tag,
        keyword_init: true
      ) do
        def binding_for_erb = binding
      end

      def initialize(project_root, cfg:, state: StateStore.new(project_root),
                     validator: nil, worktree_factory: nil, agent_runner: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @state = state
        @validator = validator || Validator.new(cfg.dig("patrol", "commands"))
        @worktree_factory = worktree_factory || method(:build_worktree)
        @agent_runner = agent_runner || method(:run_agent)
      end

      def attempt(finding)
        branch = branch_name(finding)
        worktree = @worktree_factory.call(finding: finding, branch: branch)
        worktree.create!(branch, default_branch: default_branch)
        run_dir = @state.run_dir("fix")
        output_path = File.join(run_dir, "fix.json")
        result = @agent_runner.call(finding: finding, prompt: render_prompt(finding, output_path),
                                    output_path: output_path, run_dir: run_dir,
                                    worktree_path: worktree.path)
        # Never validate or ship the output of a failed fix agent. Agent#run!
        # reports a non-zero exit or timeout via result[:status]=:error rather
        # than raising; ignoring it let a half-finished or aborted run leave
        # changes that could still pass validation, commit, and reach a PR
        # (U6 never-ship-unvalidated). Treat an errored run as a failed patch.
        return agent_failed_patch(finding, branch, worktree, result) if agent_failed?(result)

        validation = @validator.validate(worktree.path)
        changed = diff_present?(worktree.path)
        commit_changes(worktree.path, finding) if validation["passed"] && changed
        passed = validation["passed"] && (changed || committed_since_base?(worktree.path))
        patch = build_patch(finding, branch, worktree.path, validation, passed)
        @state.write_patch(patch.id, patch.to_h)
        worktree.remove!(path: worktree.path, force: true) unless passed
        patch
      rescue StandardError => e
        patch = failed_patch(finding, branch, worktree&.path, e)
        @state.write_patch(patch.id, patch.to_h)
        begin
          worktree&.remove!(path: worktree.path, force: true)
        rescue StandardError
          nil
        end
        patch
      end

      private

      def agent_failed?(result)
        result.is_a?(Hash) && result[:status] == :error
      end

      def agent_failed_patch(finding, branch, worktree, result)
        message = result.is_a?(Hash) ? result[:error_message].to_s : ""
        patch = PatchAttempt.new(
          id: "patch-#{finding.fingerprint.to_s[0, 12]}-#{SecureRandom.hex(3)}",
          finding: finding,
          branch: branch,
          worktree_path: worktree.path,
          validation: { "passed" => false, "reason" => "fix_agent_failed", "error" => message },
          passed: false,
          diffstat: "",
          head_sha: nil
        )
        @state.write_patch(patch.id, patch.to_h)
        begin
          worktree.remove!(path: worktree.path, force: true)
        rescue StandardError
          nil
        end
        patch
      end

      def build_worktree(finding:, branch:)
        slug = branch.tr("/", "-")
        root = File.join(Hive::Worktree.canonical_root(@project_root), ".patrol")
        Hive::Worktree.new(@project_root, slug, worktree_root: root)
      end

      def render_prompt(finding, output_path)
        Hive::Stages::Base.render(
          "patrol_fix_prompt.md.erb",
          TemplateBindings.new(
            project_root: @project_root,
            finding: finding,
            output_path: output_path,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def run_agent(prompt:, run_dir:, worktree_path:, **)
        task = RunnerTask.new(
          folder: run_dir,
          project_root: @project_root,
          state_file: File.join(run_dir, "fix.md"),
          log_dir: File.join(@state.root, "logs"),
          slug: "patrol-fix"
        )
        profile = Hive::AgentProfiles.lookup(@cfg.dig("patrol", "agent") || "claude", cfg: @cfg)
        started_at = Time.now.utc
        result = Hive::Agent.new(
          task: task,
          prompt: prompt,
          add_dirs: [ run_dir ],
          cwd: worktree_path,
          max_budget_usd: @cfg.dig("budget_usd", "patrol") || 100,
          timeout_sec: @cfg.dig("timeout_sec", "patrol") || 3600,
          log_label: "patrol-fix",
          profile: profile,
          status_mode: :exit_code_only,
          model_control_flags: profile.respond_to?(:render_model_controls) ?
            Hive::Config.agent_control_flags(@cfg, profile: profile, stage: :patrol_fix) : []
        ).run!
        record_usage(result, profile, "patrol-fix", started_at)
        result
      end

      def record_usage(result, profile, stage, started_at)
        usage = result && result[:usage]
        return unless usage

        Hive::UsageDb.record!(
          agent: profile_name(profile),
          model: usage[:model] || result[:model],
          project_slug: File.basename(@project_root.to_s),
          task_slug: stage,
          stage: stage,
          started_at: started_at,
          ended_at: Time.now.utc.iso8601,
          input: usage[:input] || 0,
          output: usage[:output] || 0,
          cached: usage[:cached] || 0
        )
      rescue StandardError => e
        warn "[hive] usage record failed: #{e.message}"
      end

      def profile_name(profile)
        return profile.name.to_s if profile.respond_to?(:name)

        (@cfg.dig("patrol", "agent") || "claude").to_s
      end

      def branch_name(finding)
        "hive-patrol/#{finding.feature_id}-#{finding.fingerprint.to_s[0, 8]}"
      end

      def default_branch
        @cfg["default_branch"] || Hive::GitOps.new(@project_root).detect_default_branch
      end

      def diff_present?(worktree_path)
        # `git diff --quiet` reports only unstaged changes, so a fix agent
        # that `git add`s its change (or creates a new untracked file)
        # without committing was classified as no-change — its valid fix
        # discarded and worktree removed. Stage everything, then compare
        # the index to HEAD so staged and untracked work both count.
        Open3.capture3("git", "-C", worktree_path, "add", "-A")
        _out, _err, status = Open3.capture3("git", "-C", worktree_path, "diff", "--cached", "--quiet")
        !status.success?
      end

      def committed_since_base?(worktree_path)
        _out, _err, status = Open3.capture3(
          "git", "-C", worktree_path, "diff", "--quiet", "#{default_branch}...HEAD"
        )
        !status.success?
      end

      def commit_changes(worktree_path, finding)
        Open3.capture3("git", "-C", worktree_path, "add", ".")
        _out, _err, status = Open3.capture3("git", "-C", worktree_path, "diff", "--cached", "--quiet")
        return if status.success?

        message = "fix(patrol): #{finding.title || finding.id}"
        out, err, commit_status = Open3.capture3("git", "-C", worktree_path, "commit", "-m", message)
        raise Hive::GitError, "git commit failed: #{err.strip.empty? ? out : err}" unless commit_status.success?
      end

      def build_patch(finding, branch, worktree_path, validation, passed)
        PatchAttempt.new(
          id: "patch-#{finding.fingerprint.to_s[0, 12]}-#{SecureRandom.hex(3)}",
          finding: finding,
          branch: branch,
          worktree_path: worktree_path,
          validation: validation,
          passed: passed,
          diffstat: git_output(worktree_path, "diff", "--stat", "#{default_branch}...HEAD"),
          head_sha: git_output(worktree_path, "rev-parse", "HEAD").strip
        )
      end

      def failed_patch(finding, branch, worktree_path, error)
        PatchAttempt.new(
          id: "patch-#{finding.fingerprint.to_s[0, 12]}-#{SecureRandom.hex(3)}",
          finding: finding,
          branch: branch,
          worktree_path: worktree_path,
          validation: { "passed" => false, "reason" => "fix_error", "error" => "#{error.class}: #{error.message}" },
          passed: false,
          diffstat: "",
          head_sha: nil
        )
      end

      def git_output(worktree_path, *args)
        out, = Open3.capture3("git", "-C", worktree_path, *args)
        out.to_s
      end
    end
  end
end
