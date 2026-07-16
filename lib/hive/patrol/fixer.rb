require "json"
require "open3"
require "securerandom"
require "fileutils"
require "hive/agent"
require "hive/agent_profiles"
require "hive/git_ops"
require "hive/patrol/fingerprint"
require "hive/patrol/runner_task"
require "hive/patrol/state_store"
require "hive/patrol/validator"
require "hive/stages/base"
require "hive/stages/review/fix_guardrail"
require "hive/usage_db"
require "hive/worktree"

module Hive
  module Patrol
    class Fixer
      MAX_FIX_PROOF_BYTES = 64 * 1024
      MAX_AUDITED_PATHS = 24
      MAX_REGRESSION_PATHS = 12
      VALIDATION_NAMES = %w[docs format lint public_contract typecheck test].freeze
      FAILURE_REASONS = %w[
        fix_agent_failed fix_agent_rejected missing_fix_proof no_validation_commands
        invalid_validation_key missing_regression regression_not_reproduced
        targeted_validation_failed fix_guardrail validation_mutated_worktree fix_error
      ].freeze
      HARD_GUARDRAIL_PATTERNS = {
        hive_state_edit: {
          regex: %r{(?:\A|/)\.hive-state(?:/|\z)},
          severity: :high,
          targets: :file_path,
          description: "ordinary patrol must never modify Hive's managed state"
        },
        github_workflow_edit: {
          regex: %r{(?:\A|/)\.github/workflows(?:/|\z)},
          severity: :high,
          targets: :file_path,
          description: "ordinary patrol must never modify GitHub workflow files"
        },
        patrol_mode_change: {
          # A normal new 100644 test file is safe. Block executable,
          # setuid/setgid/sticky, and world-writable tracked modes across all
          # languages instead of treating every new file header as hazardous.
          regex: %r{\A(?:old mode|new mode|deleted file mode|new file mode) 10(?:[1-7][0-7]{3}|0(?:[1357][0-7]{2}|[0-7][1357][0-7]|[0-7]{2}[2367]))\z},
          severity: :high,
          targets: :raw_diff_header,
          description: "ordinary patrol must never change tracked file modes"
        }
      }.freeze
      HARD_DEFAULT_GUARDRAILS = %i[
        ci_workflow_edit secrets_pattern_match dotenv_edit permission_change
      ].freeze

      PatchAttempt = Struct.new(:id, :finding, :branch, :worktree_path, :validation,
                                :passed, :diffstat, :base_sha, :head_sha, keyword_init: true) do
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
            "base_sha" => base_sha,
            "head_sha" => head_sha
          }
        end
      end

      TemplateBindings = Struct.new(
        :project_root, :finding, :output_path, :validation_keys,
        :max_audited_paths, :max_regression_paths, :user_supplied_tag,
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
        reusable = reusable_review_handoff_patch(finding, branch, worktree)
        return reusable if reusable

        base_sha = fresh_default_sha!
        prepare_branch_for_retry!(branch, worktree)
        worktree.create_exact!(branch, base_sha: base_sha)
        actual_base = git_output!(worktree.path, "rev-parse", "HEAD").strip
        unless actual_base == base_sha
          raise Hive::GitError,
                "patrol worktree started at #{actual_base.inspect}, expected #{base_sha.inspect}"
        end
        run_dir = @state.run_dir("fix")
        output_path = File.join(run_dir, "fix.json")
        result = @agent_runner.call(finding: finding, prompt: render_prompt(finding, output_path),
                                    output_path: output_path, run_dir: run_dir,
                                    worktree_path: worktree.path)
        # Never validate or ship the output of a failed fix agent. Agent#run!
        # reports a non-zero exit via result[:status]=:error and a timed-out
        # run via result[:status]=:timeout rather than raising; ignoring
        # either let a half-finished or aborted run leave changes that could
        # still pass validation, commit, and reach a PR
        # (U6 never-ship-unvalidated). Treat both as a failed patch.
        return agent_failed_patch(finding, branch, worktree, base_sha, result) if agent_failed?(result)

        proof, proof_error = load_fix_proof(output_path)
        if proof_error
          return proof_failed_patch(
            finding, branch, worktree, base_sha,
            proof_error.fetch("reason"), proof_error.fetch("error")
          )
        end

        validation = audit_and_validate(worktree.path, base_sha, proof)
        unless validation["passed"]
          return failed_attempt_patch(finding, branch, worktree, validation, base_sha: base_sha)
        end

        changed = diff_present?(worktree.path)
        commit_changes(worktree.path, finding) if validation["passed"] && changed
        passed = validation["passed"] && (changed || committed_since_base?(worktree.path, base_sha))
        patch = build_patch(finding, branch, worktree.path, validation, passed, base_sha)
        @state.write_patch(patch.id, patch.to_h)
        worktree.remove!(path: worktree.path, force: true) unless passed
        patch
      rescue StandardError => e
        patch = failed_patch(finding, branch, worktree&.path, base_sha, e)
        @state.write_patch(patch.id, patch.to_h)
        begin
          worktree&.remove!(path: worktree.path, force: true)
        rescue StandardError
          nil
        end
        patch
      end

      private

      def reusable_review_handoff_patch(finding, branch, worktree)
        entry = @state.fingerprints[finding.fingerprint]
        return unless entry.is_a?(Hash)
        return unless entry["state"] == "review_handoff_failed" && entry["branch"] == branch

        Dir.glob(File.join(@state.root, "patches", "*.json"))
          .sort_by { |path| -File.mtime(path).to_f }
          .each do |path|
          record = @state.read_json(path)
          next unless reusable_patch_record?(record, finding, branch, worktree.path)

          return PatchAttempt.new(
            id: record.fetch("id"), finding: finding, branch: branch,
            worktree_path: worktree.path, validation: record.fetch("validation"),
            passed: true, diffstat: record.fetch("diffstat", ""),
            base_sha: record.fetch("base_sha"), head_sha: record.fetch("head_sha")
          )
        end
        nil
      rescue SystemCallError
        nil
      end

      def reusable_patch_record?(record, finding, branch, expected_path)
        return false unless record["passed"] == true
        return false unless record["fingerprint"] == finding.fingerprint
        return false unless record["branch"] == branch && record["worktree_path"] == expected_path
        return false unless record["validation"].is_a?(Hash) && record["validation"]["passed"] == true
        return false unless record["base_sha"].to_s.match?(/\A[0-9a-f]{40,64}\z/i)
        return false unless record["head_sha"].to_s.match?(/\A[0-9a-f]{40,64}\z/i)
        return false unless File.directory?(expected_path)

        actual_head = git_output!(expected_path, "rev-parse", "HEAD").strip
        clean = git_output!(expected_path, "status", "--porcelain=v1", "--untracked-files=all").empty?
        actual_head == record["head_sha"] && clean
      rescue Hive::GitError
        false
      end

      def agent_failed?(result)
        result.is_a?(Hash) && %i[error timeout].include?(result[:status])
      end

      def agent_failed_patch(finding, branch, worktree, base_sha, result)
        message = result.is_a?(Hash) ? result[:error_message].to_s : ""
        if message.empty? && result.is_a?(Hash) && result[:status] == :timeout
          message = "fix agent timed out"
        end
        failed_attempt_patch(
          finding, branch, worktree,
          { "passed" => false, "reason" => "fix_agent_failed", "error" => message },
          base_sha: base_sha
        )
      end

      def load_fix_proof(output_path)
        content = File.open(output_path, "rb") { |file| file.read(MAX_FIX_PROOF_BYTES + 1) }
        if content.bytesize > MAX_FIX_PROOF_BYTES
          return [ nil, proof_error("missing_fix_proof", "fix proof exceeds #{MAX_FIX_PROOF_BYTES} bytes") ]
        end

        proof = JSON.parse(content)
        return [ nil, proof_error("missing_fix_proof", "fix proof must be a JSON object") ] unless proof.is_a?(Hash)

        if proof["status"] == "rejected"
          message = proof["reason"].to_s.strip
          message = "fix agent could not reproduce the finding on the current base" if message.empty?
          return [ nil, proof_error("fix_agent_rejected", message) ]
        end
        return [ nil, proof_error("missing_fix_proof", "fix proof status must be fixed or rejected") ] unless proof["status"] == "fixed"
        return [ nil, proof_error("missing_fix_proof", "fix proof must identify the root cause") ] unless present_proof_text?(proof["root_cause"])

        audited, audited_error = normalize_declared_paths(
          proof["audited_paths"], label: "audited sibling paths", max: MAX_AUDITED_PATHS
        )
        return [ nil, proof_error("missing_fix_proof", audited_error) ] if audited_error

        regressions, regression_error = normalize_declared_paths(
          proof["regression_paths"], label: "regression paths", max: MAX_REGRESSION_PATHS
        )
        return [ nil, proof_error("missing_fix_proof", regression_error) ] if regression_error

        unless present_proof_text?(proof["validation_key"])
          return [ nil, proof_error("missing_fix_proof", "fix proof must select a configured validation key") ]
        end

        [ proof.merge("audited_paths" => audited, "regression_paths" => regressions), nil ]
      rescue Errno::ENOENT
        [ nil, proof_error("missing_fix_proof", "fix agent did not write #{output_path}") ]
      rescue JSON::ParserError, SystemCallError => e
        [ nil, proof_error("missing_fix_proof", "invalid fix proof: #{e.class}: #{e.message}") ]
      end

      def present_proof_text?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def normalize_declared_paths(value, label:, max:)
        unless value.is_a?(Array) && value.any?
          return [ nil, "fix proof must list #{label}" ]
        end
        if value.length > max
          return [ nil, "fix proof must list at most #{max} #{label}" ]
        end

        normalized = value.map { |path| normalize_declared_path(path) }
        if normalized.any?(&:nil?)
          return [ nil, "fix proof #{label} must be confined relative repository paths" ]
        end

        [ normalized.uniq, nil ]
      end

      def normalize_declared_path(value)
        return unless present_proof_text?(value)

        path = value.tr("\\", "/")
        return unless path == path.strip
        return if path.start_with?("/") || path.match?(/\A[A-Za-z]:\//) || path.include?("\0")
        return if path.split("/").any? { |part| part.empty? || %w[. ..].include?(part) }

        path
      end

      def proof_error(reason, error)
        { "reason" => reason, "error" => error }
      end

      def proof_failed_patch(finding, branch, worktree, base_sha, reason, error)
        failed_attempt_patch(
          finding, branch, worktree,
          { "passed" => false, "reason" => reason, "error" => error },
          base_sha: base_sha
        )
      end

      def failed_attempt_patch(finding, branch, worktree, validation, base_sha: nil)
        patch = PatchAttempt.new(
          id: "patch-#{finding.fingerprint.to_s[0, 12]}-#{SecureRandom.hex(3)}",
          finding: finding,
          branch: branch,
          worktree_path: worktree.path,
          validation: validation,
          passed: false,
          diffstat: "",
          base_sha: base_sha,
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

      def prepare_branch_for_retry!(branch, worktree)
        unless branch.start_with?("hive-patrol/")
          raise Hive::GitError, "refusing to reset non-patrol branch #{branch.inspect}"
        end

        if worktree.respond_to?(:exists?) && worktree.exists?
          worktree.remove!(path: worktree.path, force: true)
        end

        _out, err, status = Open3.capture3(
          "git", "-C", @project_root, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"
        )
        return if status.exitstatus == 1
        unless status.success?
          raise Hive::GitError, "cannot inspect stale patrol branch #{branch}: #{err.to_s.strip}"
        end

        out, delete_err, delete_status = Open3.capture3(
          "git", "-C", @project_root, "branch", "-D", branch
        )
        return if delete_status.success?

        detail = delete_err.to_s.strip.empty? ? out.to_s.strip : delete_err.to_s.strip
        raise Hive::GitError,
              "cannot reset stale patrol branch #{branch}: #{detail} " \
              "(is it checked out in another worktree?)"
      end

      def audit_and_validate(worktree_path, base_sha, agent_proof, validation_pass: 0)
        stage_changes!(worktree_path)
        paths = changed_paths(worktree_path, base_sha)
        guarded = guard_validation(worktree_path, base_sha)
        return guarded unless guarded["passed"]

        staged_before = staged_diff(worktree_path, base_sha)
        receipt, proof_failure = machine_fix_proof(
          worktree_path, base_sha, paths, agent_proof
        )
        if proof_failure
          proof_failure["fix_proof"] = receipt if receipt
          return proof_failure
        end

        validation = @validator.validate(worktree_path)
        validation["fix_proof"] = receipt
        return validation unless validation["passed"]

        stage_changes!(worktree_path)
        guarded = guard_validation(worktree_path, base_sha)
        unless guarded["passed"]
          guarded["fix_proof"] = receipt
          return guarded
        end

        staged_after = staged_diff(worktree_path, base_sha)
        if staged_after != staged_before
          if validation_pass >= 1
            return {
              "passed" => false,
              "reason" => "validation_mutated_worktree",
              "error" => "configured validation did not converge after two machine-proof passes",
              "fix_proof" => receipt
            }
          end
          return audit_and_validate(
            worktree_path, base_sha, agent_proof, validation_pass: validation_pass + 1
          )
        end

        validation["stabilization_passes"] = validation_pass + 1
        validation
      end

      def machine_fix_proof(worktree_path, base_sha, paths, agent_proof)
        key = agent_proof.fetch("validation_key").strip
        command, selection_error = configured_validation_command(key)
        return [ nil, selection_error ] if selection_error

        audited_paths = agent_proof.fetch("audited_paths")
        tracked_paths = git_output!(worktree_path, "ls-files", "-z").split("\0").reject(&:empty?)
        unless audited_paths.all? do |path|
          paths.include?(path) ||
            (tracked_paths.include?(path) && regular_repository_file?(worktree_path, path))
        end
          return [
            nil,
            proof_validation_failure(
              "missing_fix_proof",
              "agent-reported audited paths must name changed or regular repository files"
            )
          ]
        end

        regression_paths = agent_proof.fetch("regression_paths")
        unless regression_paths.all? do |path|
          paths.include?(path) && regular_repository_file?(worktree_path, path)
        end
          return [
            nil,
            proof_validation_failure(
              "missing_regression",
              "agent-reported regression paths must be changed regular repository files"
            )
          ]
        end

        before_validation = with_control_worktree(base_sha, worktree_path) do |control_path|
          overlay_regression_paths!(worktree_path, control_path, regression_paths)
          @validator.validate(control_path, names: [ key ])
        end
        receipt = machine_receipt(
          agent_proof, base_sha, key, command, regression_paths,
          before: command_result(before_validation), after: nil
        )
        if before_validation["passed"]
          return [
            receipt,
            proof_validation_failure(
              "regression_not_reproduced",
              "the configured validation command passed on the base with the regression overlaid"
            )
          ]
        end
        unless normal_nonzero_command_result?(command_result(before_validation))
          return [
            receipt,
            proof_validation_failure(
              "regression_not_reproduced",
              "the base regression must fail with a normal nonzero exit (not timeout, signal, or exit 127)"
            )
          ]
        end
        unless regression_failure_bound?(command_result(before_validation), regression_paths)
          return [
            receipt,
            proof_validation_failure(
              "regression_not_reproduced",
              "the base failure did not identify any declared regression path"
            )
          ]
        end

        after_validation = @validator.validate(worktree_path, names: [ key ])
        receipt["after"] = command_result(after_validation)
        unless after_validation["passed"]
          return [
            receipt,
            proof_validation_failure(
              "targeted_validation_failed",
              "the configured validation command still fails on the proposed fix"
            )
          ]
        end

        [ receipt, nil ]
      end

      def configured_validation_command(key)
        commands = @cfg.dig("patrol", "commands") || {}
        if commands.values.none? { |command| present_proof_text?(command) }
          return [ nil, proof_validation_failure("no_validation_commands", "no patrol validation commands are configured") ]
        end

        command = commands[key]
        unless VALIDATION_NAMES.include?(key) && present_proof_text?(command)
          return [
            nil,
            proof_validation_failure(
              "invalid_validation_key",
              "#{key.inspect} is not an operator-configured patrol validation key"
            )
          ]
        end

        [ command, nil ]
      end

      def machine_receipt(agent_proof, base_sha, key, command, regression_paths, before:, after:)
        {
          "status" => "fixed",
          "base_sha" => base_sha,
          "root_cause" => agent_proof.fetch("root_cause"),
          "audited_paths" => agent_proof.fetch("audited_paths"),
          "validation_key" => key,
          "configured_command" => command,
          "regression_paths" => regression_paths,
          "before" => before,
          "after" => after
        }
      end

      def command_result(validation)
        Array(validation["commands"]).first
      end

      def normal_nonzero_command_result?(result)
        result.is_a?(Hash) && result["timed_out"] != true && result["signal"].nil? &&
          result["exit_code"].is_a?(Integer) && result["exit_code"].positive? &&
          result["exit_code"] != 127
      end

      def regression_failure_bound?(result, regression_paths)
        return false unless result.is_a?(Hash)

        observed = [ result["command"], result["stdout"], result["stderr"] ].join("\n")
        regression_paths.any? do |path|
          observed.include?(path) || observed.include?(File.basename(path))
        end
      end

      def proof_validation_failure(reason, error)
        { "passed" => false, "reason" => reason, "error" => error }
      end

      def with_control_worktree(base_sha, fix_worktree_path)
        control_path = File.join(
          File.dirname(fix_worktree_path),
          ".control-#{Process.pid}-#{SecureRandom.hex(6)}"
        )
        created = false
        git_output!(@project_root, "worktree", "add", "--detach", control_path, base_sha)
        created = true
        yield control_path
      ensure
        cleanup_error = nil
        if created
          out, err, status = Open3.capture3(
            "git", "-C", @project_root, "worktree", "remove", "--force", control_path
          )
          unless status.success?
            detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
            cleanup_error = "cannot remove patrol control worktree #{control_path}: #{detail}"
          end
        end
        FileUtils.rm_rf(control_path) if control_path
        if cleanup_error
          if $!
            # The block's exception is already in flight. Raising here would
            # REPLACE it (ensure raises carry no cause chain), hiding the
            # actual proof failure behind a cleanup detail. Report the
            # cleanup problem and let the original propagate.
            warn "[hive] #{cleanup_error} (while handling #{$!.class}: #{$!.message})"
          else
            raise Hive::GitError, cleanup_error
          end
        end
      end

      def overlay_regression_paths!(source_root, control_root, paths)
        paths.each do |relative_path|
          source = confined_path(source_root, relative_path)
          target = confined_path(control_root, relative_path)
          unless regular_repository_file?(source_root, relative_path)
            raise Hive::GitError, "cannot overlay missing or symlinked regression #{relative_path}"
          end

          prepare_confined_parent!(control_root, relative_path)
          raise Hive::GitError, "cannot overlay symlinked regression #{relative_path}" if File.symlink?(target)
          File.binwrite(target, File.binread(source))
          File.chmod(File.stat(source).mode & 0o777, target)
        end
      end

      def confined_path(root, relative_path)
        expanded_root = File.expand_path(root)
        expanded = File.expand_path(relative_path, expanded_root)
        prefix = "#{expanded_root}#{File::SEPARATOR}"
        unless expanded.start_with?(prefix)
          raise Hive::GitError, "regression path escapes worktree: #{relative_path.inspect}"
        end

        expanded
      end

      def regular_repository_file?(root, relative_path)
        path = confined_path(root, relative_path)
        !symlinked_component?(root, relative_path) && File.file?(path)
      end

      def prepare_confined_parent!(root, relative_path)
        current = File.expand_path(root)
        relative_path.split("/")[0...-1].each do |component|
          current = File.join(current, component)
          raise Hive::GitError, "regression parent is symlinked: #{relative_path}" if File.symlink?(current)

          FileUtils.mkdir(current) unless File.exist?(current)
          raise Hive::GitError, "regression parent is not a directory: #{relative_path}" unless File.directory?(current)
        end
      end

      def symlinked_component?(root, relative_path)
        current = File.expand_path(root)
        relative_path.split("/").any? do |component|
          current = File.join(current, component)
          File.symlink?(current)
        end
      end

      def guard_validation(worktree_path, base_sha)
        diff = staged_diff(worktree_path, base_sha)
        patterns = Hive::Stages::Review::FixGuardrail.resolve_patterns(@cfg).merge(
          hard_guardrail_patterns
        )
        matches = Hive::Stages::Review::FixGuardrail.scan_diff(diff, patterns)
        return { "passed" => true } if matches.empty?

        {
          "passed" => false,
          "reason" => "fix_guardrail",
          "matches" => matches.map(&:to_h)
        }
      end

      def hard_guardrail_patterns
        defaults = Hive::Stages::Review::FixGuardrail::Patterns::DEFAULTS
        defaults.select { |name, _| HARD_DEFAULT_GUARDRAILS.include?(name) }.merge(
          HARD_GUARDRAIL_PATTERNS
        )
      end

      def stage_changes!(worktree_path)
        git_output!(worktree_path, "add", "-A")
      end

      def changed_paths(worktree_path, base_sha)
        git_output!(worktree_path, "diff", "--cached", "--name-only", "-z", base_sha)
          .split("\0").reject(&:empty?)
      end

      def staged_diff(worktree_path, base_sha)
        git_output!(worktree_path, "diff", "--cached", "--unified=0", base_sha)
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
            validation_keys: configured_validation_keys,
            max_audited_paths: MAX_AUDITED_PATHS,
            max_regression_paths: MAX_REGRESSION_PATHS,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def configured_validation_keys
        commands = @cfg.dig("patrol", "commands") || {}
        VALIDATION_NAMES.select { |name| present_proof_text?(commands[name]) }
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
          status_mode: :exit_code_only
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

      def fresh_default_sha!
        branch = default_branch
        ref = branch
        if Hive::Worktree.origin_configured?(@project_root)
          out, err, status = Hive::Worktree.fetch_origin_branch(@project_root, branch)
          unless status.success?
            detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
            raise Hive::GitError, "cannot fetch fresh patrol base origin/#{branch}: #{detail}"
          end
          ref = "refs/remotes/origin/#{branch}"
        end

        sha = git_output!(@project_root, "rev-parse", "--verify", "#{ref}^{commit}").strip
        raise Hive::GitError, "fresh patrol base resolved an invalid SHA" unless sha.match?(/\A[0-9a-f]{40,64}\z/i)

        sha.downcase
      end

      def diff_present?(worktree_path)
        # `git diff --quiet` reports only unstaged changes, so a fix agent
        # that `git add`s its change (or creates a new untracked file)
        # without committing was classified as no-change — its valid fix
        # discarded and worktree removed. Stage everything, then compare
        # the index to HEAD so staged and untracked work both count.
        stage_changes!(worktree_path)
        _out, err, status = Open3.capture3("git", "-C", worktree_path, "diff", "--cached", "--quiet")
        return false if status.success?
        return true if status.exitstatus == 1

        raise Hive::GitError, "cannot inspect staged patrol patch: #{err.to_s.strip}"
      end

      def committed_since_base?(worktree_path, base_sha = default_branch)
        out, err, status = Open3.capture3(
          "git", "-C", worktree_path, "diff", "--quiet", "#{base_sha}...HEAD"
        )
        return false if status.success?
        return true if status.exitstatus == 1

        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise Hive::GitError, "cannot compare patrol branch with base #{base_sha}: #{detail}"
      end

      def commit_changes(worktree_path, finding)
        stage_changes!(worktree_path)
        _out, err, status = Open3.capture3("git", "-C", worktree_path, "diff", "--cached", "--quiet")
        return if status.success?
        unless status.exitstatus == 1
          raise Hive::GitError, "cannot inspect staged patrol patch: #{err.to_s.strip}"
        end

        message = "fix(patrol): #{finding.title || finding.id}"
        git_output!(worktree_path, "commit", "-m", message)
      end

      def build_patch(finding, branch, worktree_path, validation, passed, base_sha)
        PatchAttempt.new(
          id: "patch-#{finding.fingerprint.to_s[0, 12]}-#{SecureRandom.hex(3)}",
          finding: finding,
          branch: branch,
          worktree_path: worktree_path,
          validation: validation,
          passed: passed,
          diffstat: git_output!(worktree_path, "diff", "--stat", "#{base_sha}...HEAD"),
          base_sha: base_sha,
          head_sha: git_output!(worktree_path, "rev-parse", "HEAD").strip
        )
      end

      def failed_patch(finding, branch, worktree_path, base_sha, error)
        PatchAttempt.new(
          id: "patch-#{finding.fingerprint.to_s[0, 12]}-#{SecureRandom.hex(3)}",
          finding: finding,
          branch: branch,
          worktree_path: worktree_path,
          validation: { "passed" => false, "reason" => "fix_error", "error" => "#{error.class}: #{error.message}" },
          passed: false,
          diffstat: "",
          base_sha: base_sha,
          head_sha: nil
        )
      end

      def git_output!(worktree_path, *args)
        out, err, status = Open3.capture3("git", "-C", worktree_path, *args)
        return out if status.success?

        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise Hive::GitError, "git #{args.join(' ')} failed: #{detail}"
      end
    end
  end
end
