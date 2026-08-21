require "json"
require "open3"
require "securerandom"
require "tmpdir"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/patrol/fingerprint"
require "hive/patrol/finding_registry"
require "hive/patrol/finding_query"
require "hive/patrol/feature_batch"
require "hive/patrol/mapper"
require "hive/patrol/reviewer"
require "hive/patrol/decision_projection"
require "hive/patrol/state_store"
require "hive/patrol/launch_budget"
require "hive/workflows"
require "hive/worktree"

module Hive
  module Commands
    class Patrol
      def initialize(project, json: false, dry_run: false, list: false,
                     mapper_factory: nil, reviewer_factory: nil,
                     project_entry: nil,
                     capability_context: nil, module_execution: nil,
                     occurrence_id: nil, capture: nil,
                     migration_authority: :legacy,
                     evidence_store_factory: nil,
                     clock: -> { Time.now.utc },
                     config_loader: ->(path) { Hive::Config.load(path) })
        @project = project
        @json = json
        @dry_run = dry_run
        @list = list
        @mapper_factory = mapper_factory || lambda do |root, cfg, state|
          Hive::Patrol::Mapper.new(root, cfg: cfg, state: state, capabilities: [ :architecture ])
        end
        @reviewer_factory = reviewer_factory
        @project_entry = project_entry
        @capability_context = capability_context
        @module_execution = module_execution
        @occurrence_id = occurrence_id
        @capture = capture
        @migration_authority = migration_authority.to_s
        @evidence_store_factory = evidence_store_factory || lambda do |entry|
          Hive::Modules::Migration::EvidenceStore.new(
            root: File.join(
              entry.fetch("hive_state_path"), "module-runtime", "migration",
              "patrol-evidence"
            )
          )
        end
        @clock = clock
        @config_loader = config_loader
      end

      def call
        return list_findings if @list

        emit(run_cycle)
      rescue Hive::Error => e
        emit_error(e)
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error(wrapped)
        raise wrapped
      end

      private

      def list_findings
        entry = @project_entry || Hive::Config.find_project(@project)
        raise Hive::ConfigError, "hive patrol: unknown project #{@project.inspect}" unless entry

        store = Hive::Patrol::StateStore.new(
          entry.fetch("path"), hive_state_path: entry.fetch("hive_state_path")
        )
        query = Hive::Patrol::FindingQuery.new(store)
        payload = query.list_envelope(
          project: entry.fetch("name"), project_root: entry.fetch("path")
        )
        puts(@json ? JSON.generate(payload) : query.text(payload))
        payload
      end

      def run_cycle
        entry = @project_entry || Hive::Config.find_project(@project)
        raise Hive::ConfigError, "hive patrol: unknown project #{@project.inspect}" unless entry

        project_root = entry.fetch("path")
        cfg = @config_loader.call(project_root)
        unless Hive::Workflows.coding_id?(cfg["default_workflow"])
          raise Hive::ConfigError,
                "hive patrol: project #{entry.fetch('name').inspect} uses non-coding " \
                "default_workflow #{cfg['default_workflow'].inspect}"
        end
        require_module_observation_capabilities!
        require_module_mutation_capabilities! unless @dry_run
        state = Hive::Patrol::StateStore.new(
          project_root, hive_state_path: entry.fetch("hive_state_path")
        )
        state.with_cycle_lock do
          run_locked_cycle(entry, project_root, cfg, state)
        end
      end

      def run_locked_cycle(entry, project_root, cfg, state)
        capture = patrol_capture(entry, state)
        unless @dry_run
          state.configure_effect_gateway!(
            capture: capture,
            evidence_store: @evidence_store_factory.call(entry),
            config_loader: @config_loader,
            capability_checker: method(:effect_capability_allowed?),
            module_execution: @module_execution
          )
          state.recover_pending_fingerprint_effects!
        end
        launch_budget = Hive::Patrol::LaunchBudget.new(
          project_root, cfg: cfg, project_id: entry.fetch("project_id"),
          project_name: entry.fetch("name"), engine: :ordinary
        )
        target_sha = sweep_target_sha(project_root, cfg, state)
        features, feature_batch, reviewer, findings = with_scan_checkout(project_root, target_sha) do |scan_root|
          mapped = @mapper_factory.call(scan_root, cfg, state).call
          batch = Hive::Patrol::FeatureBatch.new(cfg: cfg, state: state).call(
            mapped, target_sha: target_sha,
            limit: review_launch_limit(cfg, launch_budget)
          )
          scan_reviewer = build_reviewer(scan_root, cfg, state, launch_budget)
          reviewed = stamp_findings(
            scan_reviewer.call(batch.features), scan_root,
            target_sha: target_sha, cfg: cfg
          )
          [ mapped, batch, scan_reviewer, reviewed ]
        end
        review = review_outcome(feature_batch, reviewer)

        registry = Hive::Patrol::FindingRegistry.new(state: state, target_sha: target_sha)
        admission = registry.admit(findings, retry_active: !@dry_run)
        findings = admission.findings
        candidates = findings
        skipped = admission.skipped
        # Persist only after target binding, semantic deduplication, lifecycle
        # admission, and portfolio scoring. The reviewer itself is a pure
        # producer and cannot accumulate untriaged duplicates.
        unless @dry_run
          admission.persistable_findings.each { |finding| state.write_finding(finding) }
          write_selection_audit(state, candidates, skipped)
        end

        # Only advance the scanned-SHA watermark when every feature
        # reviewed cleanly. If any feature's reviewer agent failed or
        # returned malformed JSON, leaving last_scanned_sha unchanged lets
        # the next cycle re-review this commit instead of treating a
        # partial scan as a clean pass and never looking again (U5).
        now_iso = Time.now.utc.iso8601
        if @dry_run
          scanned_sha = state.state["last_scanned_sha"].to_s
        elsif review.fetch("review_errors").any?
          state.update_state(
            "last_run_at" => now_iso,
            "feature_review_active" => true,
            "feature_review_sha" => target_sha,
            "feature_review_cursor" => retry_feature_cursor(
              feature_batch, review.fetch("review_errors")
            )
          )
          scanned_sha = state.state["last_scanned_sha"].to_s
        elsif feature_batch.complete
          scanned_sha = target_sha
          state.update_state(
            "last_run_at" => now_iso,
            "last_scanned_sha" => scanned_sha,
            "feature_review_active" => false,
            "feature_review_sha" => target_sha,
            "feature_review_cursor" => 0
          )
        else
          scanned_sha = state.state["last_scanned_sha"].to_s
          state.update_state(
            "last_run_at" => now_iso,
            "feature_review_active" => true,
            "feature_review_sha" => target_sha,
            "feature_review_cursor" => feature_batch.next_cursor
          )
        end
        state.rebuild_finding_query_projection! unless @dry_run
        payload = success_payload(
          entry, project_root, scanned_sha, features, review,
          findings, candidates, skipped
        )
        finalize_manual_occurrence!(
          entry, state, capture, payload
        ) if @occurrence_id.nil? && !@dry_run
        payload
      end

      def require_module_observation_capabilities!
        return unless @capability_context

        @capability_context.require_filesystem_read!("repository")
        @capability_context.require_external_command!("git")
      end

      def require_module_mutation_capabilities!
        return unless @capability_context

        @capability_context.require_filesystem_write!(".hive-state/patrol/**")
      end

      def patrol_capture(entry, state)
        capture = @capture
        capture ||= state.occurrence_capture(@occurrence_id) if @occurrence_id
        if @occurrence_id && capture.nil?
          raise Hive::ConfigError,
                "patrol reservation capture #{@occurrence_id.inspect} is unavailable"
        end
        if @occurrence_id.nil? && !@dry_run && state.recovery_active?
          raise Hive::ConfigError,
                "patrol cycle is already reserved; wait for daemon recovery"
        end
        capture ||= build_manual_capture(entry)
        validate_capture!(capture, entry)
        state.reserve_occurrence!(capture) unless @dry_run
        capture
      end

      def build_manual_capture(entry)
        Hive::Modules::Migration::Patrols.with_migration_lock(
          entry.fetch("path"),
          hive_state_path: entry.fetch("hive_state_path"),
          shared: true
        ) do
          snapshot = Hive::Modules::Migration::Patrols.ownership_snapshot(
            entry.fetch("path"), "patrol",
            hive_state_path: entry.fetch("hive_state_path")
          )
          unless snapshot["owner"] == @migration_authority &&
                 snapshot["admission"] == true &&
                 snapshot["epoch"].to_i.positive?
            raise Hive::ConfigError,
                  "patrol mutation authority is not admitted"
          end

          now = @clock.call
          identity = [
            "manual", entry.fetch("project_id"), now.utc.iso8601(6)
          ].join(":")
          selection_input =
            Hive::Patrol::DecisionProjection.operation_input("manual")
          Hive::Modules::Migration::PatrolCapture.build(
            module_name: "patrol",
            project: {
              "project_id" => entry.fetch("project_id"),
              "name" => entry.fetch("name"),
              "repository" => entry["repository_identity"]
            },
            trigger: { "kind" => "manual", "id" => identity },
            reservation: { "kind" => "ordinary", "id" => identity },
            owner: snapshot.fetch("owner"),
            owner_epoch: snapshot.fetch("epoch"),
            selection_input: selection_input,
            selection:
              Hive::Modules::Migration::PatrolDecisionProjection.build(
                module_name: "patrol",
                rationale: "due"
              ),
            outcome_class: nil,
            outcome: nil,
            occurred_at: now,
            recorded_at: now
          )
        end
      end

      def validate_capture!(capture, entry)
        valid = capture.is_a?(Hive::Modules::Migration::PatrolCapture) &&
                capture.module_name == "patrol" &&
                capture.project.fetch("project_id") == entry.fetch("project_id").to_s &&
                capture.project.fetch("name") == entry.fetch("name").to_s &&
                capture.owner == @migration_authority
        return true if valid

        raise Hive::ConfigError,
              "patrol reservation capture does not match the command project or authority"
      rescue KeyError
        raise Hive::ConfigError,
              "patrol reservation capture does not match the command project or authority"
      end

      def effect_capability_allowed?(capability:, capability_context: nil, **)
        context = capability_context || @capability_context
        return true unless context

        case capability.to_s
        when "filesystem_write"
          context.require_filesystem_write!(".hive-state/patrol/**")
        else
          return false
        end
        true
      rescue Hive::Modules::CapabilityDenied
        false
      end

      def finalize_manual_occurrence!(entry, state, provisional, payload)
        capture = Hive::Modules::Migration::PatrolCapture.build(
          module_name: "patrol",
          project: provisional.project,
          trigger: provisional.trigger,
          reservation: provisional.reservation,
          owner: provisional.owner,
          owner_epoch: provisional.owner_epoch,
          selection_input: provisional.selection_input,
          selection: provisional.selection,
          outcome_class: "completed",
          outcome: {
            "rationale" => "manual_completed",
            "ok" => payload.fetch("ok"),
            "findings" => payload.fetch("findings"),
            "fixes_attempted" => payload.fetch("fixes_attempted"),
            "prs_opened" => payload.fetch("prs_opened"),
            "review_complete" => payload.fetch("review_complete")
          },
          effect_ids: state.terminal_effect_receipt_ids(
            provisional.occurrence_id
          ),
          occurred_at: provisional.occurred_at,
          recorded_at: @clock.call
        )
        state.finalize_occurrence!(
          capture: capture,
          evidence_store: @evidence_store_factory.call(entry)
        )
      end

      def review_outcome(feature_batch, reviewer)
        attempted = feature_batch.features.size
        errors = reviewer.respond_to?(:review_errors) ? Array(reviewer.review_errors) : []
        failed_indices = review_failure_indices(feature_batch, errors)
        # An un-attributable error makes the successful count unknowable. Fail
        # closed instead of claiming that every attempted feature completed.
        succeeded = if errors.any? && failed_indices.nil?
          0
        else
          attempted - Array(failed_indices).size
        end
        {
          "features_review_attempted" => attempted,
          "features_reviewed" => succeeded,
          "review_complete" => errors.empty? && feature_batch.complete,
          "review_errors" => errors
        }
      end

      # A later feature failure must pin that feature, not replay already-clean
      # leading features. Unattributable errors still fail closed at the batch
      # start because Hive cannot prove which feature completed.
      def retry_feature_cursor(feature_batch, errors)
        failed_indices = review_failure_indices(feature_batch, Array(errors))
        return feature_batch.start_cursor unless failed_indices

        feature_batch.start_cursor + failed_indices.min.to_i
      end

      def review_failure_indices(feature_batch, errors)
        attempted_ids = feature_batch.features.map { |feature| feature.id.to_s }
        indices = errors.filter_map do |error|
          next unless error.is_a?(Hash)

          id = (error["feature_id"] || error[:feature_id]).to_s
          attempted_ids.index(id)
        end
        return unless indices.size == errors.size && indices.uniq.size == errors.size

        indices
      end

      def build_reviewer(root, cfg, state, launch_budget)
        return @reviewer_factory.call(root, cfg, state) if @reviewer_factory

        Hive::Patrol::Reviewer.new(root, cfg: cfg, state: state, launch_budget: launch_budget)
      end

      # The allowance counts discovery launches only. Remediation is owned by
      # workflow concurrency, so all ordinary headroom is available to review.
      def review_launch_limit(_cfg, launch_budget)
        launch_budget.remaining_launches
      end

      def stamp_findings(findings, project_root, target_sha:, cfg:)
        configured_keys = Hive::Patrol::Validator.configured_names(cfg.dig("patrol", "commands"))
        findings.each do |finding|
          finding.fingerprint ||= Hive::Patrol::Fingerprint.compute(finding, project_root: project_root)
          finding.target_sha = target_sha
          finding.validation_key ||= configured_keys.first if configured_keys.one?
        end
      end

      def current_default_sha(project_root, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        ref = branch
        if Hive::Worktree.origin_configured?(project_root)
          out, err, status = Hive::Worktree.fetch_origin_branch(project_root, branch)
          unless status.success?
            detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
            raise Hive::GitError,
                  "cannot fetch fresh patrol scan base origin/#{branch}: #{detail}"
          end
          ref = "refs/remotes/origin/#{branch}"
        end

        out, err, status = Open3.capture3(
          "git", "-C", project_root, "rev-parse", "--verify", "#{ref}^{commit}"
        )
        unless status.success?
          detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
          raise Hive::GitError, "git rev-parse #{ref} failed: #{detail}"
        end

        sha = out.strip
        unless sha.match?(/\A[0-9a-f]{40,64}\z/i)
          raise Hive::GitError, "fresh patrol scan base resolved an invalid SHA"
        end

        sha.downcase
      end

      def sweep_target_sha(project_root, cfg, state)
        snapshot = state.state
        cursor = snapshot["feature_review_cursor"].to_i
        active_sha = snapshot["feature_review_sha"].to_s
        active = snapshot["feature_review_active"] == true
        legacy_active = !snapshot.key?("feature_review_active") && cursor.positive?
        if (active || legacy_active) && materializable_commit?(project_root, active_sha)
          return active_sha.downcase
        end

        current_default_sha(project_root, cfg)
      end

      def materializable_commit?(project_root, sha)
        return false unless sha.match?(/\A[0-9a-f]{40,64}\z/i)

        _out, _err, status = Open3.capture3(
          "git", "-C", project_root, "rev-parse", "--verify", "#{sha}^{commit}"
        )
        status.success?
      end

      def with_scan_checkout(project_root, target_sha)
        Dir.mktmpdir("hive-patrol-scan-") do |parent|
          scan_root = File.join(parent, "checkout")
          attached = false
          git_output!(project_root, "worktree", "add", "--detach", scan_root, target_sha)
          attached = true
          actual_sha = git_output!(scan_root, "rev-parse", "HEAD").strip
          unless actual_sha == target_sha
            raise Hive::GitError,
                  "patrol scan checkout resolved #{actual_sha.inspect}, expected #{target_sha.inspect}"
          end

          result = yield scan_root
          assert_clean_scan_checkout!(scan_root, target_sha)
          result
        ensure
          remove_scan_checkout!(project_root, scan_root) if attached
        end
      end

      def assert_clean_scan_checkout!(scan_root, target_sha)
        observed_sha = git_output!(scan_root, "rev-parse", "HEAD").strip
        unless observed_sha == target_sha
          raise Hive::GitError, "patrol reviewer changed its detached scan commit"
        end

        status = git_output!(scan_root, "status", "--porcelain", "--untracked-files=all")
        return if status.empty?

        raise Hive::GitError, "patrol reviewer modified its detached scan checkout"
      end

      # Cleanup failure must never mask the scan outcome: raising here would
      # replace an in-flight reviewer exception (losing its cause) or — worse —
      # discard a SUCCESSFULLY completed review cycle as an internal error.
      # A leaked checkout is recoverable (each cycle creates a fresh
      # Dir.mktmpdir path, so stale worktree metadata cannot collide with or
      # corrupt the next scan and `git worktree prune` reclaims it); a
      # discarded clean review cycle is not. Warn and continue.
      def remove_scan_checkout!(project_root, scan_root)
        git_output!(project_root, "worktree", "remove", "--force", scan_root)
      rescue Hive::GitError => e
        warn "hive patrol: failed to remove detached scan checkout #{scan_root}: #{e.message}"
      end

      def git_output!(root, *args)
        out, err, status = Open3.capture3("git", "-C", root, *args)
        return out if status.success?

        detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
        raise Hive::GitError, "git #{args.join(' ')} failed: #{detail}"
      end

      def write_selection_audit(state, candidates, skipped)
        now = Time.now.utc
        id = "selection-#{now.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
        state.write_run_log(id, {
          "schema" => "hive-patrol-selection",
          "schema_version" => 1,
          "created_at" => now.iso8601,
          "ranked_candidates" => candidates.map do |finding|
            {
              "finding_id" => finding.id,
              "feature_id" => finding.feature_id,
              "fingerprint" => finding.fingerprint,
              "category" => finding.category,
              "alpha_score" => finding.alpha_score,
              "target_sha" => finding.target_sha,
              "validation_key" => finding.validation_key
            }
          end,
          "skipped" => skipped
        })
      end

      def success_payload(entry, project_root, sha, features, review, findings, candidates, skipped)
        {
          "schema" => "hive-patrol",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-patrol"),
          "ok" => true,
          "project" => entry.fetch("name"),
          "project_root" => project_root,
          "dry_run" => @dry_run,
          "features_mapped" => features.size,
          "features_review_attempted" => review.fetch("features_review_attempted"),
          "features_reviewed" => review.fetch("features_reviewed"),
          "review_complete" => review.fetch("review_complete"),
          "review_errors" => review.fetch("review_errors"),
          "findings" => findings.size,
          "fix_candidates" => candidates.size,
          "fixes_attempted" => 0,
          "fixes_validated" => 0,
          "prs_opened" => 0,
          "pr_urls" => [],
          "review_handoff_errors" => [],
          "fix_results" => [],
          "skipped_findings" => skipped,
          "last_scanned_sha" => sha
        }
      end

      def emit(payload)
        if @json
          puts JSON.generate(payload)
        else
          puts "hive patrol: #{payload['project']} mapped=#{payload['features_mapped']} " \
               "findings=#{payload['findings']} fixes=#{payload['fixes_validated']} " \
               "prs=#{payload['prs_opened']}"
        end
        payload
      end

      def emit_error(error)
        return unless @json

        payload = if @list
          Hive::Patrol::FindingQuery.error_envelope(error)
        else
          {
            "schema" => "hive-patrol",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-patrol"),
            "ok" => false,
            "error_class" => error.class.name.split("::").last,
            "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "error",
            "exit_code" => error.exit_code,
            "message" => error.message
          }
        end
        puts JSON.generate(payload)
      end
    end
  end
end
