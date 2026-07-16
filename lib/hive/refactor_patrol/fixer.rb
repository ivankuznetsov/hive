require "json"
require "open3"
require "fileutils"
require "hive/agent"
require "hive/agent_profiles"
require "hive/patrol/architecture_mapper"
require "hive/patrol/runner_task"
require "hive/patrol/token_budget"
require "hive/patrol/validator"
require "hive/refactor_patrol/caps"
require "hive/secret_patterns"
require "hive/stages/base"
require "hive/stages/review/fix_guardrail"
require "hive/worktree"

module Hive
  module RefactorPatrol
    # Applies one accepted thesis inside a deterministic isolated worktree and
    # returns publication evidence. It never pushes or mutates registered
    # trunk; PrOpener owns the external transition after these guards pass.
    class Fixer
      STAGE = "refactor-patrol-fix".freeze
      Result = Struct.new(
        :outcome, :terminal, :branch, :worktree_path, :analysis_sha,
        :publication_base_sha, :commit_sha, :validation, :changed_paths,
        :diff_lines, :details,
        keyword_init: true
      ) do
        def publishable?
          outcome == "validated" && terminal == false
        end

        def passed = publishable?
        def head_sha = commit_sha
      end

      TemplateBindings = Struct.new(:worktree_path, :thesis, :user_supplied_tag, keyword_init: true) do
        def binding_for_erb = binding
      end

      VALIDATION_NAMES = %w[docs format lint public_contract typecheck test].freeze
      CONFIDENCE_ORDER = { "low" => 0, "medium" => 1, "high" => 2 }.freeze

      def initialize(project_root, cfg:, worktree_factory: nil, agent_runner: nil,
                     validator_factory: nil, public_contract_guard: Caps,
                     clock: nil, token_budget: nil)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @worktree_factory = worktree_factory || method(:build_worktree)
        @agent_runner = agent_runner || method(:run_agent)
        @validator_factory = validator_factory || ->(commands) { Hive::Patrol::Validator.new(commands) }
        @public_contract_guard = public_contract_guard
        @token_budget = token_budget || Hive::Patrol::TokenBudget.new(@project_root, cfg: cfg)
      end

      def attempt(thesis:, job_id:, analysis_sha:, canonical_action_id: nil,
                  reanalysis_depth: 0,
                  report_analysis_sha: analysis_sha)
        return blocked("not_accepted", thesis: thesis) unless accepted?(thesis)

        branch = branch_name(job_id, thesis.fingerprint, canonical_action_id)
        worktree = @worktree_factory.call(branch: branch)
        registered_checkout = registered_checkout_snapshot!(analysis_sha)
        materialized = worktree.create_exact!(branch, base_sha: analysis_sha)
        if materialized == :existing && !git_output!(worktree.path, "status", "--porcelain=v1", "-z").empty?
          return transient(
            "dirty_worktree_recovered", branch, worktree,
            status: :error, error_message: "discarded an incomplete prior fix attempt"
          )
        end

        existing_head = git_output!(worktree.path, "rev-parse", "HEAD").strip
        recovering_commit = materialized == :existing && existing_head != analysis_sha
        patch_base =
          if recovering_commit
            recovered_patch_base!(
              worktree.path, analysis_sha, registered_checkout.fetch(:head)
            )
          else
            analysis_sha
          end
        unless recovering_commit
          control_plane = control_plane_snapshot(
            worktree.path, registered_checkout.fetch(:status)
          )
          agent_result = @agent_runner.call(
            thesis: thesis, prompt: render_prompt(thesis, worktree.path), worktree_path: worktree.path,
            run_dir: run_dir(job_id, thesis.fingerprint)
          )
          changed = control_plane_changes(control_plane, worktree.path)
          unless changed.empty?
            cleanup(worktree)
            return Result.new(
              outcome: "agent_control_plane_violation", terminal: true,
              branch: branch, worktree_path: worktree.path, analysis_sha: analysis_sha,
              details: { "changed" => changed }
            )
          end
          return transient("fix_agent_failed", branch, worktree, agent_result) if agent_failed?(agent_result)
        end

        audit = audit_and_validate(thesis, worktree.path, patch_base)
        return finish_audit_failure(audit, branch, worktree, analysis_sha) unless audit.fetch(:passed)

        commit_audited_changes!(worktree.path, thesis, amend: recovering_commit)
        publication_base = reconcile_trunk_drift(
          thesis, worktree, branch, analysis_sha, patch_base, registered_checkout
        )
        if publication_base.is_a?(Result)
          if publication_base.outcome == "trunk_overlap_reanalysis_required" && reanalysis_depth.zero?
            git_output!(@project_root, "branch", "-D", branch)
            retried = attempt(
              thesis: thesis,
              job_id: job_id,
              canonical_action_id: canonical_action_id,
              analysis_sha: publication_base.publication_base_sha,
              reanalysis_depth: reanalysis_depth + 1,
              report_analysis_sha: report_analysis_sha
            )
            retried.analysis_sha = report_analysis_sha
            retried.details = (retried.details || {}).merge(
              "reanalyzed_after_trunk_overlap" => true,
              "reanalysis_sha" => publication_base.publication_base_sha,
              "overlap" => publication_base.details.fetch("overlap")
            )
            return retried
          end
          publication_base.analysis_sha = report_analysis_sha
          return publication_base
        end

        if publication_base != patch_base
          audit = audit_and_validate(thesis, worktree.path, publication_base)
          return finish_audit_failure(audit, branch, worktree, analysis_sha) unless audit.fetch(:passed)

          commit_audited_changes!(worktree.path, thesis, amend: true)
        end
        assert_clean_worktree!(worktree.path)
        assert_registered_checkout!(registered_checkout)

        Result.new(
          outcome: "validated", terminal: false, branch: branch, worktree_path: worktree.path,
          analysis_sha: analysis_sha, publication_base_sha: publication_base,
          commit_sha: git_output!(worktree.path, "rev-parse", "HEAD").strip,
          validation: audit.fetch(:validation), changed_paths: audit.fetch(:paths),
          diff_lines: audit.fetch(:diff_lines), details: {}
        )
      rescue Hive::ConfigError, ArgumentError => e
        # Configuration and identity errors are permanent for this action;
        # retrying can only reproduce them, so the result is terminal.
        cleanup(worktree)
        Result.new(
          outcome: "fix_error", terminal: true, branch: branch,
          worktree_path: worktree&.path, analysis_sha: analysis_sha,
          details: { "error" => "#{e.class}: #{e.message}" }
        )
      rescue StandardError => e
        cleanup(worktree)
        Result.new(
          outcome: "fix_error", terminal: false, branch: branch,
          worktree_path: worktree&.path, analysis_sha: analysis_sha,
          details: { "error" => "#{e.class}: #{e.message}" }
        )
      end

      private

      def accepted?(thesis)
        minimum = CONFIDENCE_ORDER.fetch(@cfg.dig("refactor_patrol", "min_confidence") || "medium", 1)
        confidence = CONFIDENCE_ORDER.fetch(thesis.confidence.to_s, -1)
        thesis.admissible == true && confidence >= minimum &&
          Array(thesis.risk && thesis.risk["flags"]).empty?
      end

      def branch_name(job_id, fingerprint, canonical_action_id)
        if canonical_action_id
          action = canonical_action_id.to_s
          unless action.match?(/\Afix-[0-9a-f]{64}\z/)
            raise ArgumentError, "canonical fix action identity is invalid"
          end

          return "hive-refactor/#{action}"
        end

        # Backward-compatible direct Fixer callers can still produce a local
        # patch, but ActionRunner accepts only the repository-global branch.
        job = job_id.to_s.gsub(/[^a-zA-Z0-9_.-]+/, "-")[0, 48]
        token = fingerprint.to_s.gsub(/[^a-zA-Z0-9]+/, "")[0, 16]
        "hive-refactor/#{job}-#{token}"
      end

      def build_worktree(branch:)
        configured_root = @cfg["worktree_root"] ||
                          Hive::Worktree.default_worktree_root(File.basename(@project_root))
        root = File.join(File.expand_path(configured_root), ".refactor-patrol")
        Hive::Worktree.new(@project_root, branch.tr("/", "-"), worktree_root: root)
      end

      # Every audit diff disables rename detection: a detected rename reports
      # only its destination path and a near-zero line count, which would let
      # the vacated source path slip past the boundary, contract, and cap
      # guards below. With --no-renames both endpoints surface as a deletion
      # plus an addition and enter every guard.
      def audit_and_validate(thesis, path, base_sha, validation_pass: 0)
        git_output!(path, "add", "-A")
        paths = nul_paths(git_output!(path, "diff", "--cached", "--no-renames", "--name-only", "-z", base_sha))
        return { passed: false, outcome: "no_diff", details: {}, paths: [], diff_lines: 0 } if paths.empty?

        symlinked = paths.select { |changed| symlinked_path?(path, changed) }.sort
        return audit_failure("symlinked_path", paths, symlinked_paths: symlinked) if symlinked.any?

        boundary = Array(thesis.feature_boundary && thesis.feature_boundary["owned_files"]) +
                   Array(thesis.feature_boundary && thesis.feature_boundary["entrypoints"])
        outside = paths - boundary
        return audit_failure("boundary_violation", paths, outside: outside) unless outside.empty?

        diff_lines = diff_line_count!(path, base_sha)
        caps = @cfg.dig("refactor_patrol", "caps") || {}
        if paths.size > caps.fetch("max_files", 8).to_i || diff_lines > caps.fetch("max_diff_lines", 400).to_i
          return audit_failure("caps_exceeded", paths, diff_lines: diff_lines)
        end
        if !caps.fetch("allow_dependency_bumps", false) &&
           paths.any? { |changed| Caps.dependency_manifest?(changed) }
          return audit_failure("dependency_change", paths, diff_lines: diff_lines)
        end

        diff = git_output!(path, "diff", "--cached", "--no-renames", "--unified=0", base_sha)
        source_paths = paths.select do |changed|
          source_change_path?(path, base_sha, changed)
        end.sort
        contract_paths = paths.select do |changed|
          source_paths.include?(changed) || @public_contract_guard.public_api_path?(changed)
        end
        configured_contract_guard = !configured_commands["public_contract"].to_s.strip.empty?
        unless caps.fetch("allow_public_api_changes", false)
          if !configured_contract_guard && paths.any? { |changed| @public_contract_guard.public_api_path?(changed) }
            return audit_failure("public_contract_change", paths, diff_lines: diff_lines)
          end

          unsupported_paths = source_paths.select do |changed|
            !@public_contract_guard.public_contract_guard_available?(changed)
          end.sort
          if unsupported_paths.any? && !configured_contract_guard
            return audit_failure(
              "public_contract_safety_unavailable", paths,
              diff_lines: diff_lines, unsupported_paths: unsupported_paths
            )
          end

          if !configured_contract_guard && paths.any? { |changed| public_declaration_changed?(path, base_sha, changed) }
            return audit_failure("public_contract_change", paths, diff_lines: diff_lines)
          end
        end

        patterns = Hive::Stages::Review::FixGuardrail.resolve_patterns(@cfg)
        matches = Hive::Stages::Review::FixGuardrail.scan_diff(diff, patterns)
        return audit_failure("fix_guardrail", paths, matches: matches.map(&:to_h)) unless matches.empty?
        secret_hits = Hive::SecretPatterns.scan(diff)
        return audit_failure("secret_detected", paths, secret_patterns: secret_hits.map { |hit| hit[:name].to_s }.uniq) if secret_hits.any?

        names = Array(thesis.required_validation && thesis.required_validation["commands"]).map(&:to_s).uniq
        names << "public_contract" if configured_contract_guard && contract_paths.any?
        return audit_failure("missing_validation", paths, diff_lines: diff_lines) if names.empty?
        unless (names - VALIDATION_NAMES).empty? && names.all? { |name| configured_commands[name].to_s.strip != "" }
          return audit_failure("missing_validation", paths, diff_lines: diff_lines, required: names)
        end

        validation_head = git_output!(path, "rev-parse", "HEAD").strip
        validation = @validator_factory.call(configured_commands).validate(path, names: names)
        unless validation["passed"]
          return audit_failure("validation_failed", paths, diff_lines: diff_lines, validation: validation)
        end

        # A configured formatter is allowed to converge the proposed patch,
        # but Hive must validate and commit the same bytes. Restage and rerun
        # the complete guard/validation sequence once when a command mutates
        # the diff; a second mutation is non-convergent and fails closed.
        git_output!(path, "add", "-A")
        current_head = git_output!(path, "rev-parse", "HEAD").strip
        if current_head != validation_head
          return audit_failure(
            "validation_changed_head", paths, diff_lines: diff_lines,
            validation: validation
          )
        end
        validated_diff = git_output!(path, "diff", "--cached", "--no-renames", "--unified=0", base_sha)
        if validated_diff != diff
          if validation_pass >= 1
            return audit_failure(
              "validation_mutated_worktree", paths, diff_lines: diff_lines,
              validation: validation
            )
          end
          return audit_and_validate(
            thesis, path, base_sha, validation_pass: validation_pass + 1
          )
        end

        validation = validation.merge("stabilization_passes" => validation_pass + 1)
        { passed: true, paths: paths, diff_lines: diff_lines, validation: validation }
      end

      def audit_failure(outcome, paths, **details)
        { passed: false, outcome: outcome, paths: paths, diff_lines: details[:diff_lines], details: details }
      end

      def finish_audit_failure(audit, branch, worktree, analysis_sha)
        cleanup(worktree)
        Result.new(
          outcome: audit.fetch(:outcome), terminal: true, branch: branch,
          worktree_path: worktree.path, analysis_sha: analysis_sha,
          validation: audit.dig(:details, :validation), changed_paths: audit[:paths],
          diff_lines: audit[:diff_lines], details: stringify(audit.fetch(:details))
        )
      end

      def reconcile_trunk_drift(thesis, worktree, branch, analysis_sha, patch_base, registered_checkout)
        current = assert_registered_checkout!(registered_checkout)
        return patch_base if current == patch_base

        drift_paths = nul_paths(
          git_output!(@project_root, "diff", "--no-renames", "--name-only", "-z", "#{analysis_sha}..#{current}")
        )
        boundary = Array(thesis.feature_boundary && thesis.feature_boundary["owned_files"]) +
                   Array(thesis.feature_boundary && thesis.feature_boundary["entrypoints"])
        overlap = drift_paths & boundary
        unless overlap.empty?
          cleanup(worktree)
          return Result.new(
          outcome: "trunk_overlap_reanalysis_required", terminal: false,
            branch: branch, worktree_path: worktree.path,
            analysis_sha: analysis_sha, publication_base_sha: current,
            details: { "overlap" => overlap }
          )
        end

        git_output!(worktree.path, "rebase", current)
        current
      end

      def commit_changes!(path, thesis)
        title = thesis.problem.to_s.lines.first.to_s.strip[0, 72]
        git_output!(path, "commit", "-m", "refactor: #{title.empty? ? thesis.id : title}")
      end

      def commit_audited_changes!(path, thesis, amend:)
        return unless staged_changes?(path)

        if amend
          git_output!(path, "commit", "--amend", "--no-edit")
        else
          commit_changes!(path, thesis)
        end
        assert_clean_worktree!(path)
      end

      def staged_changes?(path)
        _out, err, status = Open3.capture3("git", "-C", path, "diff", "--cached", "--quiet", "HEAD")
        return false if status.success?
        return true if status.exitstatus == 1

        raise Hive::GitError, "cannot inspect staged refactor patch: #{err}"
      end

      def assert_clean_worktree!(path)
        status = git_output!(path, "status", "--porcelain=v1", "-z")
        raise Hive::GitError, "refactor patch worktree is dirty after commit" unless status.empty?
      end

      def diff_line_count!(path, base_sha)
        git_output!(path, "diff", "--cached", "--no-renames", "--numstat", base_sha).lines.sum do |line|
          added, removed, = line.split("\t", 3)
          raise Hive::GitError, "cannot count binary diff safely" if added == "-" || removed == "-"

          added.to_i + removed.to_i
        end
      end

      def public_declaration_changed?(worktree_path, base_sha, changed_path)
        after = File.file?(File.join(worktree_path, changed_path)) ?
          File.binread(File.join(worktree_path, changed_path)) : ""
        before =
          begin
            git_output!(worktree_path, "show", "#{base_sha}:#{changed_path}")
          rescue Hive::GitError
            # `git show` fails identically for a genuinely new file and for a
            # broken audit base. Only a verified base commit that lacks the
            # blob means "new file"; any other git failure re-raises so a
            # deleted public declaration can never pass unaudited. A new file
            # has no base signatures, so any explicit public declaration in it
            # is a contract expansion and therefore fails closed.
            raise unless new_path_at_base?(worktree_path, base_sha, changed_path)

            return @public_contract_guard.public_declaration_signatures(changed_path, after).any?
          end
        @public_contract_guard.public_declaration_signatures(changed_path, before) !=
          @public_contract_guard.public_declaration_signatures(changed_path, after)
      end

      def new_path_at_base?(worktree_path, base_sha, changed_path)
        _out, err, commit = Open3.capture3(
          "git", "-C", worktree_path, "cat-file", "-e", "#{base_sha}^{commit}"
        )
        unless commit.success?
          raise Hive::GitError,
                "cannot verify refactor audit base commit #{base_sha}: #{err.to_s.strip}"
        end

        _out, _err, blob = Open3.capture3(
          "git", "-C", worktree_path, "cat-file", "-e", "#{base_sha}:#{changed_path}"
        )
        !blob.success?
      end

      # Git commits a symlink as a small target blob, but every filesystem
      # audit here reads through the live path, so audited bytes could diverge
      # from committed bytes and a committed link can point outside the
      # repository. Reject any changed path whose final entry or directory
      # component is a symlink inside the worktree.
      def symlinked_path?(worktree_path, changed_path)
        current = File.expand_path(worktree_path)
        changed_path.split("/").any? do |component|
          current = File.join(current, component)
          begin
            File.lstat(current).symlink?
          rescue Errno::ENOENT, Errno::ENOTDIR
            false
          end
        end
      end

      def source_change_path?(worktree_path, base_sha, changed_path)
        return true if Hive::Patrol::ArchitectureMapper.source_candidate_path?(changed_path)
        return false unless File.extname(changed_path).empty?

        current_path = File.join(worktree_path, changed_path)
        return true if File.file?(current_path) && File.binread(current_path, 2) == "#!"

        out, err, status = Open3.capture3(
          "git", "-C", worktree_path, "show", "#{base_sha}:#{changed_path}"
        )
        return out.start_with?("#!") if status.success?
        return false if File.file?(current_path)

        raise Hive::GitError,
              "cannot inspect the base form of extensionless refactor path #{changed_path}: " \
              "#{err.to_s.strip.empty? ? out : err}"
      end

      def configured_commands
        @cfg.dig("refactor_patrol", "commands") || {}
      end

      def render_prompt(thesis, worktree_path)
        Hive::Stages::Base.render(
          "refactor_patrol_fix_prompt.md.erb",
          TemplateBindings.new(
            worktree_path: worktree_path, thesis: thesis,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
      end

      def run_agent(prompt:, worktree_path:, run_dir:, **)
        FileUtils.mkdir_p(run_dir)
        task = Hive::Patrol::RunnerTask.new(
          folder: run_dir, project_root: @project_root,
          state_file: File.join(run_dir, "fix.md"),
          log_dir: File.join(@project_root, ".hive-state", "refactor_patrol", "v2", "logs"),
          slug: STAGE
        )
        profile = fix_profile
        unless @token_budget.acquire(stage: STAGE)
          return { status: :error, error_message: @token_budget.exhaustion_message }
        end
        started_at = Time.now.utc
        result = nil
        begin
          result = Hive::Agent.new(
            task: task, prompt: prompt, add_dirs: [], cwd: worktree_path,
            max_budget_usd: @token_budget.max_budget_usd(
              @cfg.dig("budget_usd", "patrol") || 100, stage: STAGE
            ),
            max_tokens: @token_budget.max_tokens(stage: STAGE),
            timeout_sec: @cfg.dig("timeout_sec", "patrol") || 3600,
            log_label: STAGE, profile: profile, status_mode: :exit_code_only,
            permission_mode: Hive::AgentProfile::WORKSPACE_WRITE_PERMISSION_MODE
          ).run!
        ensure
          @token_budget.record!(
            result: result, profile: profile, stage: STAGE, started_at: started_at
          )
        end
        result
      end

      def fix_profile
        name = @cfg.dig("refactor_patrol", "auto_fix", "agent") || "codex"
        profile = Hive::AgentProfiles.lookup(name, cfg: @cfg)
        unless profile.workspace_write_supported?
          raise Hive::ConfigError,
                "refactor patrol auto-fix provider #{profile.name.inspect} cannot enforce " \
                "workspace-write isolation; configure refactor_patrol.auto_fix.agent: codex"
        end

        profile
      end

      def run_dir(job_id, fingerprint)
        File.join(
          @project_root, ".hive-state", "refactor_patrol", "v2", "runs",
          "fix-#{job_id.to_s.gsub(/[^a-zA-Z0-9_.-]+/, '-')[0, 48]}-#{fingerprint.to_s[0, 12]}"
        )
      end

      def agent_failed?(result)
        !result.is_a?(Hash) || result[:status] != :ok
      end

      # The Codex workspace-write sandbox is the primary confinement layer.
      # These snapshots are defense in depth around Git's shared control
      # plane: a linked worktree keeps its refs and config outside the
      # writable worktree root, and an auto-fix agent must never alter them.
      # The configured default branch is intentionally omitted from the ref
      # snapshot because it may advance concurrently and is reconciled below.
      def control_plane_snapshot(worktree_path, registered_status)
        common_dir = git_output!(worktree_path, "rev-parse", "--git-common-dir").strip
        common_dir = File.expand_path(common_dir, worktree_path)
        fix_branch_ref = git_output!(worktree_path, "symbolic-ref", "HEAD").strip
        {
          git_pointer: file_identity(File.join(worktree_path, ".git")),
          shared_config_path: File.join(common_dir, "config"),
          shared_git_config: file_identity(File.join(common_dir, "config")),
          fix_branch_ref: fix_branch_ref,
          fix_branch_oid: git_output!(worktree_path, "rev-parse", fix_branch_ref).strip,
          registered_checkout: registered_status
        }
      end

      def control_plane_changes(before, worktree_path)
        checks = {
          "worktree_git_pointer" => -> { file_identity(File.join(worktree_path, ".git")) },
          "shared_git_config" => -> { file_identity(before.fetch(:shared_config_path)) },
          "fix_branch_ref" => lambda do
            git_output!(worktree_path, "rev-parse", before.fetch(:fix_branch_ref)).strip
          end,
          "registered_checkout" => -> { git_output!(@project_root, "status", "--porcelain=v1", "-z") }
        }
        expected = {
          "worktree_git_pointer" => before.fetch(:git_pointer),
          "shared_git_config" => before.fetch(:shared_git_config),
          "fix_branch_ref" => before.fetch(:fix_branch_oid),
          "registered_checkout" => before.fetch(:registered_checkout)
        }

        checks.each_with_object([]) do |(name, reader), changed|
          actual = reader.call
          changed << name unless actual == expected.fetch(name)
        rescue StandardError
          changed << name
        end
      end

      def file_identity(path)
        stat = File.lstat(path)
        content = stat.file? ? File.binread(path) : nil
        [ stat.ftype, stat.mode & 0o7777, content ]
      rescue Errno::ENOENT
        [ "missing", nil, nil ]
      end

      def transient(outcome, branch, worktree, result)
        cleanup(worktree)
        Result.new(
          outcome: outcome, terminal: false, branch: branch, worktree_path: worktree.path,
          details: { "error" => result.is_a?(Hash) ? result[:error_message].to_s : "" }
        )
      end

      def blocked(outcome, thesis:)
        Result.new(outcome: outcome, terminal: true, details: { "thesis_id" => thesis.id.to_s })
      end

      def cleanup(worktree)
        worktree&.remove!(path: worktree.path, force: true)
      rescue StandardError
        nil
      end

      def registered_checkout_snapshot!(analysis_sha)
        branch = git_output!(@project_root, "branch", "--show-current").strip
        expected = @cfg.fetch("default_branch").to_s
        unless !branch.empty? && branch == expected
          raise Hive::GitError,
                "registered checkout must remain on configured default branch #{expected.inspect}"
        end

        head = git_output!(@project_root, "rev-parse", "HEAD").strip
        assert_ancestor!(analysis_sha, head, "registered checkout no longer contains the analysis commit")
        status = git_output!(@project_root, "status", "--porcelain=v1", "-z")
        raise Hive::GitError, "registered checkout must be clean before refactor fix" unless status.empty?

        {
          branch: branch,
          head: head,
          status: status
        }
      end

      def recovered_patch_base!(worktree_path, analysis_sha, registered_head)
        ancestry = git_output!(worktree_path, "rev-list", "--parents", "-n", "1", "HEAD").split
        unless ancestry.size == 2
          raise Hive::GitError, "recovered refactor patch must contain exactly one non-merge commit"
        end

        parent = ancestry.fetch(1)
        assert_ancestor!(analysis_sha, parent, "recovered refactor base no longer descends from analysis")
        assert_ancestor!(parent, registered_head, "recovered refactor base is not on registered trunk")
        parent
      end

      def assert_registered_checkout!(before)
        branch = git_output!(@project_root, "branch", "--show-current").strip
        unless branch == before.fetch(:branch)
          raise Hive::GitError,
                "registered checkout left configured default branch #{before.fetch(:branch).inspect}"
        end
        status = git_output!(@project_root, "status", "--porcelain=v1", "-z")
        unless status == before.fetch(:status)
          raise Hive::GitError, "registered checkout changed during refactor fix"
        end

        head = git_output!(@project_root, "rev-parse", "HEAD").strip
        assert_ancestor!(before.fetch(:head), head, "registered checkout no longer descends from its validated head")
        head
      end

      def assert_ancestor!(ancestor, descendant, message)
        _out, _err, status = Open3.capture3(
          "git", "-C", @project_root, "merge-base", "--is-ancestor", ancestor, descendant
        )
        raise Hive::GitError, message unless status.success?
      end

      def git_output!(directory, *args)
        out, err, status = Open3.capture3("git", "-C", directory, *args)
        return out if status.success?

        raise Hive::GitError, "git #{args.join(' ')} failed: #{err.to_s.strip.empty? ? out : err}"
      end

      def nul_paths(value)
        value.split("\0").reject(&:empty?)
      end

      def stringify(value)
        JSON.parse(JSON.generate(value))
      end
    end
  end
end
