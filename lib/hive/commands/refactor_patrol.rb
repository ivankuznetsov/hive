require "json"
require "fileutils"
require "open3"
require "securerandom"
require "set"
require "time"
require "uri"
require "hive/config"
require "hive/atomic_file"
require "hive/git_ops"
require "hive/lock"
require "hive/process_kill"
require "hive/patrol/mapper"
require "hive/patrol/token_budget"
require "hive/refactor_patrol/caps"
require "hive/refactor_patrol/action_runner"
require "hive/refactor_patrol/collisions"
require "hive/refactor_patrol/checkout_guard"
require "hive/refactor_patrol/fingerprint"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/job_query"
require "hive/refactor_patrol/leverage"
require "hive/refactor_patrol/policy"
require "hive/refactor_patrol/process_group_resolver"
require "hive/refactor_patrol/pr_manifest"
require "hive/refactor_patrol/pr_manifest_resolver"
require "hive/refactor_patrol/reporter"
require "hive/refactor_patrol/repository_ownership"
require "hive/refactor_patrol/reviewer"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis"
require "hive/worktree"

module Hive
  module Commands
    class RefactorPatrol
      CLAIM_HEARTBEAT_INTERVAL_SEC = 30
      CLAIM_HEARTBEAT_LEASE_SEC = 7200

      # Unlike the expired-claim resolver, heartbeat liveness checks are
      # strictly observational: a live worker must never be terminated merely
      # to prove that it still owns its lease.
      class ClaimLivenessResolver
        def call(claim)
          child = !claim["pid"].nil?
          pid = Integer(child ? claim.fetch("pid") : claim.fetch("owner_pid"))
          recorded_start = claim.fetch(
            child ? "process_start_time" : "owner_process_start_time"
          ).to_s
          return :resolved unless Hive::ProcessKill.valid_target_pid?(pid)
          return :resolved if recorded_start.empty? || !Hive::ProcessKill.pid_alive?(pid)
          return :resolved unless Hive::ProcessKill.process_start_time(pid).to_s == recorded_start
          return :resolved if child && Process.getpgid(pid) != Integer(claim.fetch("pgid"))

          :unresolved
        rescue KeyError, ArgumentError, TypeError, Errno::EPERM, Errno::ESRCH
          :resolved
        end
      end

      def initialize(project, json: false, dry_run: false, feature: nil, entrypoint: nil, path: nil, changed_since: nil, pr: nil,
                     job_manifest: nil, actions: false, result_file: nil, list: false, show: nil,
                     limit: nil, cursor: nil, full: false,
                     mapper_factory: nil, reviewer_factory: nil, leverage_factory: nil,
                     caps_factory: nil, collisions_factory: nil, manifest_resolver_factory: nil,
                     action_runner_factory: nil, job_store_factory: nil,
                     repository_ownership: nil, checkout_guard_factory: nil,
                     analysis_worktree_factory: nil,
                     heartbeat_interval_sec: CLAIM_HEARTBEAT_INTERVAL_SEC,
                     heartbeat_lease_sec: CLAIM_HEARTBEAT_LEASE_SEC,
                     heartbeat_clock: -> { Time.now }, heartbeat_resolver: ClaimLivenessResolver.new)
        @project = project
        @json = json
        @dry_run = dry_run
        @feature_hint = feature
        @entrypoint_hint = entrypoint
        @path_hint = path
        @changed_since = changed_since
        @pr = pr
        @job_manifest = job_manifest
        @actions = actions
        @result_file = result_file
        @list_jobs = list == true
        @show_job = show
        @query_limit = limit
        @query_cursor = cursor
        @query_full = full == true
        @mapper_factory = mapper_factory || lambda do |root, cfg, state|
          Hive::Patrol::Mapper.new(
            root,
            cfg: mapper_cfg(cfg),
            state: state,
            dry_run: ephemeral_discovery?,
            capabilities: %i[architecture documentation],
            documentation_changes: pr_mode? ? @manifest.fetch("files") : []
          )
        end
        @reviewer_factory = reviewer_factory
        @leverage_factory = leverage_factory || ->(root, cfg) { Hive::RefactorPatrol::Leverage.new(root, cfg: cfg) }
        @caps_factory = caps_factory || ->(cfg) { Hive::RefactorPatrol::Caps.new(cfg) }
        @collisions_factory = collisions_factory || lambda do |root, state, v2_fingerprints|
          Hive::RefactorPatrol::Collisions.new(
            root, state: state, v2_fingerprints: v2_fingerprints
          )
        end
        @manifest_resolver_factory = manifest_resolver_factory
        @repository_ownership = repository_ownership || Hive::RefactorPatrol::RepositoryOwnership.new
        @action_runner_factory = action_runner_factory
        @job_store_factory = job_store_factory || ->(root) { Hive::RefactorPatrol::JobStore.new(root) }
        @checkout_guard_factory = checkout_guard_factory || lambda do |root, branch|
          Hive::RefactorPatrol::CheckoutGuard.new(root, default_branch: branch)
        end
        @analysis_worktree_factory = analysis_worktree_factory || method(:build_analysis_worktree)
        @heartbeat_interval_sec = heartbeat_interval_sec.to_f
        @heartbeat_lease_sec = heartbeat_lease_sec.to_i
        @heartbeat_clock = heartbeat_clock
        @heartbeat_resolver = heartbeat_resolver
      end

      def call
        validate_mode!
        return run_job_query if query_mode?
        return emit(run_action_cycle, []) if @actions

        payload, theses = run_cycle
        emit(payload, theses)
      rescue Hive::Error => e
        release_manual_claim("command_error")
        emit_error(e)
        raise
      rescue StandardError => e
        release_manual_claim("command_error")
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error(wrapped)
        raise wrapped
      end

      private

      def run_action_cycle
        entry, project_root, cfg = resolve_project!
        @manifest = resolve_manifest(entry, project_root, cfg)
        validate_result_file!(project_root) if @result_file
        @job_store = @job_store_factory.call(project_root)
        assert_repository_ownership!(
          entry, cfg, aggregate: @job_store.read_job(@manifest.fetch("job_id"))
        )
        token_budget = Hive::Patrol::TokenBudget.new(project_root, cfg: cfg)
        runner = build_action_runner(project_root, cfg, token_budget)
        result = with_claim_heartbeat(@manifest.fetch("job_id")) do
          runner.run(job_id: @manifest.fetch("job_id"), dry_run: @dry_run)
        end
        build_action_payload(entry, project_root, result)
      end

      def run_cycle
        entry, project_root, cfg = resolve_project!
        assert_repository_ownership!(entry, cfg) if pr_mode?
        @manifest = resolve_manifest(entry, project_root, cfg) if pr_mode?
        validate_result_file!(project_root) if @result_file
        prepare_checkout_and_discovery!(entry, project_root, cfg) if pr_mode?
        if @existing_lifecycle
          return [ lifecycle_payload(entry, project_root, @existing_lifecycle), lifecycle_theses(@existing_lifecycle) ]
        end
        analysis_root = pr_mode? ? materialize_analysis_worktree!(project_root, cfg) : project_root
        state = Hive::RefactorPatrol::StateStore.new(project_root)
        # A dry run must not create durable artifacts under
        # .hive-state/refactor_patrol/; all reads tolerate a missing dir.
        state.ensure! unless ephemeral_discovery?

        features = scoped_features(analysis_root, cfg, state)
        completed = completed_feature_results
        existing_theses = prior_theses
        existing_suppressions = prior_suppressions
        pending_features = features.reject { |feature| completed.key?(feature.id.to_s) }
        token_budget = Hive::Patrol::TokenBudget.new(project_root, cfg: cfg)
        review_features = bounded_review_features(pending_features, token_budget)
        reviewer = build_reviewer(analysis_root, cfg, state, token_budget)
        yielded_thesis_ids = {}
        incrementally_suppressed = []
        completed_new_theses = []
        completed_new_suppressions = []
        completed_new_results = {}
        new_theses = with_claim_heartbeat(@manifest&.fetch("job_id", nil)) do
          reviewer.call(
            review_features,
            leverage_by_feature: score_features(review_features, analysis_root, cfg)
          ) do |reviewed_feature, feature_theses, feature_result|
            guarded = guard_theses(feature_theses, project_root, cfg, state)
            incrementally_suppressed.concat(guarded)
            feature_theses.each do |thesis|
              yielded_thesis_ids[[ thesis.feature_id.to_s, thesis.id.to_s ]] = true
            end
            next unless feature_result["complete"] == true

            completed_new_theses.concat(feature_theses)
            completed_new_suppressions.concat(guarded)
            completed_new_results[reviewed_feature.id.to_s] = feature_result
            checkpoint_completed_features!(
              entry, project_root, cfg, state, features, completed,
              existing_theses, existing_suppressions, completed_new_theses,
              completed_new_suppressions, completed_new_results, reviewer
            )
          end
        end
        assert_analysis_worktree! if pr_mode?
        unyielded = new_theses.reject do |thesis|
          yielded_thesis_ids[[ thesis.feature_id.to_s, thesis.id.to_s ]]
        end
        new_suppressed = incrementally_suppressed + guard_theses(unyielded, project_root, cfg, state)
        theses = existing_theses + new_theses
        suppressed = existing_suppressions + new_suppressed
        feature_results = merged_feature_results(
          completed, reviewer, review_features, new_theses
        )
        result_ids = feature_results.to_h { |item| [ item.fetch("feature_id").to_s, true ] }
        reported_features = features.select { |feature| result_ids[feature.id.to_s] }
        scope_complete = pending_features.all? { |feature| result_ids[feature.id.to_s] }

        unless ephemeral_discovery?
          persist(state, theses, suppressed)
          update_scan_state(state, project_root, cfg, reviewer)
        end
        payload = build_payload(
          entry, project_root, cfg, state, reported_features, theses, suppressed,
          reviewer, feature_results: feature_results, complete: scope_complete
        )
        cleanup_analysis_worktree! if pr_mode?
        checkpoint_manual_discovery!(payload) if @manual_claim_token
        [ payload, theses ]
      ensure
        cleanup_analysis_worktree!(raise_on_drift: $!.nil?)
      end

      def resolve_project!
        entry = Hive::Config.find_project(@project)
        raise Hive::ConfigError, "hive refactor-patrol: unknown project #{@project.inspect}" unless entry

        project_root = entry.fetch("path")
        cfg = Hive::Config.load(project_root)
        unless query_mode? || @actions || (cfg["refactor_patrol"] || {})["enabled"]
          raise Hive::ConfigError, "hive refactor-patrol: project #{entry.fetch('name').inspect} must opt in with refactor_patrol.enabled: true"
        end

        [ entry, project_root, cfg ]
      end

      def assert_repository_ownership!(entry, cfg, aggregate: nil)
        source = aggregate&.fetch("source", nil)
        expected = Hive::RefactorPatrol::RepositoryOwnership.identity_from_source(source) if source
        decision = @repository_ownership.call(
          entry: entry,
          cfg: cfg,
          expected_identity: expected,
          continuation: aggregate && Hive::RefactorPatrol::RepositoryOwnership.continuation_evidence?(aggregate),
          continuation_owner: aggregate && Hive::RefactorPatrol::RepositoryOwnership
            .remote_continuation_evidence?(aggregate)
        )
        return unless decision.blocked?
        return if aggregate && decision.reason == "architecture_patrol_disabled"

        raise Hive::ConfigError,
              "hive refactor-patrol: #{decision.reason}: #{JSON.generate(decision.evidence)}"
      end

      def scoped_features(project_root, cfg, state)
        features = @mapper_factory.call(project_root, cfg, state).call
        return scope_to_manifest(features) if pr_mode?

        apply_scope_hints(features, project_root)
      end

      def score_features(features, project_root, cfg)
        changed = changed_files(project_root)
        leverage = @leverage_factory.call(project_root, cfg)
        baseline = pr_mode? ? @manifest.dig("source", "base_sha") : @changed_since
        features.to_h do |feature|
          boost = changed_path?(feature.owned_files, changed)
          [ feature.id, leverage.score(feature, changed_since: baseline, changed_boost: boost) ]
        end
      end

      def guard_theses(theses, project_root, cfg, state)
        caps = @caps_factory.call(cfg)
        collisions = build_collisions(project_root, state)
        theses.filter_map do |thesis|
          caps.apply(thesis)
          if Array(thesis.risk && thesis.risk["flags"]).include?("below_min_leverage")
            next({ "id" => thesis.id, "reason" => "below_min_leverage" })
          end

          collision = collisions.check(thesis)
          { "id" => thesis.id, "reason" => collision.reason, "reference" => collision.reference } if collision.suppressed
        end
      end

      def build_collisions(project_root, state)
        fingerprints = v2_terminal_fingerprints(project_root)
        if @collisions_factory.arity == 2
          @collisions_factory.call(project_root, state)
        else
          @collisions_factory.call(project_root, state, fingerprints)
        end
      end

      def v2_terminal_fingerprints(project_root)
        return {} unless pr_mode?
        return {} if @explicit_replay

        store = @job_store || @job_store_factory.call(project_root)
        if @dry_run
          store.jobs.select { |job| job.fetch("complete") }.each_with_object({}) do |job, result|
            Hive::RefactorPatrol::JobStore::DISPOSITIONS.each do |name|
              job.dig("dispositions", name).each do |item|
                result[item.fetch("fingerprint")] = { "job_id" => job.fetch("job_id") }
              end
            end
          end
        else
          store.fingerprint_index.fetch("fingerprints")
        end
      end

      def build_payload(entry, project_root, cfg, state, features, theses, suppressed, reviewer,
                        feature_results: nil, complete: nil)
        @reporter = Hive::RefactorPatrol::Reporter.new(cfg)
        return build_v2_payload(
          entry, project_root, features, theses, suppressed, reviewer,
          feature_results: feature_results, complete: complete
        ) if pr_mode?

        scanned_sha = @dry_run ? current_default_sha(project_root, cfg) : state.state["last_scanned_sha"].to_s
        @reporter.envelope(
          project: entry.fetch("name"),
          project_root: project_root,
          dry_run: @dry_run,
          features: features,
          theses: theses,
          suppressed: suppressed,
          last_scanned_sha: scanned_sha,
          complete: Array(reviewer.review_errors).empty?,
          review_errors: reviewer.review_errors,
          feature_results: feature_results,
          version: Hive::RefactorPatrol::Reporter::V1_SCHEMA_VERSION
        )
      end

      def build_reviewer(root, cfg, state, token_budget)
        return @reviewer_factory.call(root, cfg, state) if @reviewer_factory

        Hive::RefactorPatrol::Reviewer.new(
          root,
          cfg: cfg,
          state: state,
          # PR-scoped discovery is read-only, but it is still a real daemon
          # run whose prompt, logs, and raw final message must remain auditable.
          dry_run: @dry_run,
          source_pr: pr_mode? ? source_pr_context : nil,
          read_only: pr_mode?,
          audit_context: pr_mode? ? {
            "job_id" => @manifest.fetch("job_id"),
            "analysis_sha" => @checkout_snapshot.fetch("analysis_sha"),
            "source_pr" => source_pr_context
          } : nil,
          token_budget: token_budget
        )
      end

      def build_action_runner(root, cfg, token_budget)
        return @action_runner_factory.call(root, cfg) if @action_runner_factory

        Hive::RefactorPatrol::ActionRunner.new(
          root, cfg: cfg, registration: @project,
          repository_ownership: @repository_ownership,
          token_budget: token_budget
        )
      end

      def persist(state, theses, suppressed)
        suppressed_ids = suppressed.map { |item| item.fetch("id") }
        fingerprints = state.fingerprints
        theses.each do |thesis|
          state.write_thesis(thesis)
          next if suppressed_ids.include?(thesis.id)

          Hive::RefactorPatrol::Fingerprint.record_seen(fingerprints, thesis.fingerprint, thesis: thesis)
        end
        state.write_fingerprints(fingerprints)
      end

      def update_scan_state(state, project_root, cfg, reviewer)
        now_iso = Time.now.utc.iso8601
        if reviewer.respond_to?(:review_errors) && Array(reviewer.review_errors).any?
          state.update_state("last_run_at" => now_iso)
        else
          state.update_state("last_run_at" => now_iso, "last_scanned_sha" => current_default_sha(project_root, cfg))
        end
      end

      def apply_scope_hints(features, project_root)
        scoped =
          if @feature_hint
            features.select { |feature| feature.id == @feature_hint }
          elsif @entrypoint_hint
            features.select { |feature| Array(feature.entrypoints).include?(@entrypoint_hint) }
          elsif @path_hint
            normalized = @path_hint.tr("\\", "/")
            features.select { |feature| Array(feature.owned_files).any? { |path| path == normalized || path.start_with?("#{normalized}/") } }
          else
            features
          end

        return scoped unless @changed_since && (@feature_hint || @entrypoint_hint || @path_hint)

        changed = changed_files(project_root)
        # A git failure yields nil (distinct from an empty "no changes" diff);
        # degrade to the scoped set rather than filtering it down to zero, in
        # keeping with the churn/leverage graceful-degradation posture.
        return scoped if changed.nil?

        scoped.select { |feature| (Array(feature.owned_files) & changed).any? }
      end

      def changed_files(project_root)
        return @manifest.fetch("changed_paths") if pr_mode?
        return @changed_files if defined?(@changed_files)

        @changed_files = compute_changed_files(project_root)
      end

      def compute_changed_files(project_root)
        return [] unless @changed_since

        out, _err, status = Open3.capture3("git", "-C", project_root, "diff", "--name-only", @changed_since, "HEAD")
        # nil signals a git failure so callers can degrade gracefully; [] means
        # the diff succeeded with no changed files.
        return nil unless status.success?

        out.lines.map { |line| line.strip.tr("\\", "/") }.reject(&:empty?)
      rescue StandardError
        nil
      end

      def current_default_sha(project_root, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        out, _err, status = Open3.capture3("git", "-C", project_root, "rev-parse", branch)
        return "" unless status.success?

        out.strip
      end

      def mapper_cfg(cfg)
        clone = Hive::Config.deep_dup(cfg)
        clone["patrol"] = (clone["patrol"] || {}).merge(
          "include" => cfg.dig("refactor_patrol", "include"),
          "exclude" => cfg.dig("refactor_patrol", "exclude"),
          "review" => cfg.dig("refactor_patrol", "review")
        )
        clone
      end

      def validate_mode!
        if query_requested? && !query_mode?
          raise Hive::RefactorPatrol::JobQuery::UsageError,
                "hive refactor-patrol --limit/--cursor/--full require --list or --show"
        end
        if query_mode?
          if @list_jobs && @show_job
            raise Hive::RefactorPatrol::JobQuery::UsageError,
                  "hive refactor-patrol accepts only one of --list or --show"
          end
          incompatible = [
            @pr, @job_manifest, @result_file, @feature_hint, @entrypoint_hint,
            @path_hint, @changed_since
          ].any? { |value| !value.nil? } || @actions || @dry_run
          if incompatible
            raise Hive::RefactorPatrol::JobQuery::UsageError,
                  "hive refactor-patrol --list/--show cannot be combined with discovery or action options"
          end
          if @query_cursor && !@list_jobs
            raise Hive::RefactorPatrol::JobQuery::UsageError,
                  "hive refactor-patrol --cursor requires --list"
          end
          if @query_full && !@show_job
            raise Hive::RefactorPatrol::JobQuery::UsageError,
                  "hive refactor-patrol --full requires --show"
          end
          if @query_full && !@query_limit.nil?
            raise Hive::RefactorPatrol::JobQuery::UsageError,
                  "hive refactor-patrol --full cannot be combined with --limit"
          end
          Hive::RefactorPatrol::JobQuery.normalize_limit(@query_limit) unless @query_full
          Hive::RefactorPatrol::JobQuery.decode_cursor(@query_cursor) if @query_cursor
          Hive::RefactorPatrol::JobQuery.validate_job_id!(@show_job) if @show_job
          return
        end

        if @result_file && (!@json || !@job_manifest || @pr)
          raise Hive::ConfigError,
                "hive refactor-patrol --result-file requires --job-manifest and --json"
        end
        if @actions
          unless @json && @job_manifest && !@pr
            raise Hive::ConfigError,
                  "hive refactor-patrol --actions requires --job-manifest and --json"
          end
          hints = [ @feature_hint, @entrypoint_hint, @path_hint, @changed_since ]
          if hints.any? { |value| !value.nil? }
            raise Hive::ConfigError,
                  "hive refactor-patrol --actions cannot be combined with discovery scope hints"
          end
          return
        end

        return unless pr_mode?

        unless @json
          raise Hive::ConfigError, "hive refactor-patrol PR-scoped mode requires --json"
        end
        if @pr && @job_manifest
          raise Hive::ConfigError, "hive refactor-patrol accepts only one of --pr or --job-manifest"
        end
        hints = [ @feature_hint, @entrypoint_hint, @path_hint, @changed_since ]
        if hints.any? { |value| !value.nil? }
          raise Hive::ConfigError,
                "hive refactor-patrol --pr cannot be combined with --feature, --entrypoint, --path, or --changed-since"
        end
      end

      def resolve_manifest(entry, project_root, cfg)
        return load_job_manifest!(entry, project_root, cfg) if @job_manifest

        factory = @manifest_resolver_factory || lambda do |root, registration, project_cfg|
          Hive::RefactorPatrol::PrManifestResolver.new(
            project_root: root,
            registration: registration,
            default_branch: project_cfg["default_branch"] || Hive::GitOps.new(root).default_branch,
            cfg: project_cfg,
            dry_run: @dry_run
          )
        end
        factory.call(project_root, entry.fetch("name"), cfg).resolve(@pr)
      end

      def prepare_durable_discovery!(entry, project_root, cfg)
        @job_store = @job_store_factory.call(project_root)
        aggregate = if @pr
          @job_store.enqueue_manifest!(
            @manifest,
            policy: Hive::RefactorPatrol::Policy.capture(cfg),
            now: Time.now
          )
        else
          @job_store.read_job(@manifest.fetch("job_id"))
        end
        if @pr && aggregate.fetch("complete")
          @manifest = publish_manual_replay_manifest!(project_root, @manifest)
          @explicit_replay = true
          aggregate = @job_store.enqueue_manifest!(
            @manifest,
            policy: Hive::RefactorPatrol::Policy.capture(cfg),
            now: Time.now
          )
        end
        unless aggregate.fetch("source") == source_pr_context
          raise Hive::ConfigError, "refactor patrol manifest does not match its authoritative job"
        end
        @durable_aggregate = aggregate
        return unless @pr

        if aggregate.fetch("complete") || %w[classified acting].include?(aggregate.fetch("state")) ||
           aggregate.fetch("actions").any?
          @existing_lifecycle = aggregate
          return
        end

        # A completed PR is replaced by a replay manifest above. Pin only
        # after that replacement so a new replay samples the current default
        # branch instead of inheriting the completed occurrence's snapshot.
        # Incomplete occurrences still reuse their durable analysis_sha.
        pin_checkout!(project_root, cfg)
        process_start_time = Hive::Lock.process_start_time(Process.pid)
        if process_start_time.to_s.empty?
          raise Hive::ConfigError, "refactor patrol cannot verify the current process identity"
        end
        @manual_claim_token = @job_store.claim_discovery!(
          aggregate.fetch("job_id"),
          owner: "manual-#{Process.pid}-#{process_start_time}",
          analysis_sha: @checkout_snapshot.fetch("analysis_sha"),
          now: Time.now,
          claim_resolver: Hive::RefactorPatrol::ProcessGroupResolver.new,
          owner_pid: Process.pid,
          owner_process_start_time: process_start_time
        )
        unless @manual_claim_token
          raise Hive::ConfigError, "refactor patrol job is already claimed by another worker"
        end
        @durable_aggregate = @job_store.read_job(aggregate.fetch("job_id"))
      end

      def publish_manual_replay_manifest!(project_root, original)
        root = File.join(
          project_root, ".hive-state", "refactor_patrol", "v2", "manifests"
        )
        FileUtils.mkdir_p(root)
        File.open(File.join(root, "manual-replays.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          base = original.fetch("job_id").to_s[0, 100]
          sequence = Dir.glob(File.join(root, "#{base}-replay-*.json")).filter_map do |path|
            File.basename(path, ".json")[/\A#{Regexp.escape(base)}-replay-(\d+)\z/, 1]&.to_i
          end.max.to_i + 1
          job_id = "#{base}-replay-#{sequence}"
          payload = original.merge("job_id" => job_id).reject do |key, _value|
            key == "manifest_checksum"
          end
          manifest = payload.merge(
            "manifest_checksum" => Hive::RefactorPatrol::PrManifest.checksum(payload)
          )
          Hive::RefactorPatrol::PrManifest.validate!(
            manifest,
            expected_job_id: job_id,
            registration: original.dig("source", "registration"),
            default_branch: original.dig("source", "base_branch")
          )
          Hive::AtomicFile.write(
            File.join(root, "#{job_id}.json"),
            "#{JSON.pretty_generate(manifest)}\n", mode: 0o600
          )
          File.open(root, File::RDONLY) { |directory| directory.fsync }
          manifest
        end
      end

      def checkpoint_manual_discovery!(payload)
        @durable_aggregate = @job_store.checkpoint_discovery!(
          @manual_claim_token, envelope: payload, now: Time.now
        )
        @manual_claim_token = nil
      end

      def checkpoint_completed_features!(entry, project_root, cfg, state, features, completed,
                                         existing_theses, existing_suppressions,
                                         new_theses, new_suppressions, new_results, reviewer)
        return unless pr_mode? && !@dry_run && @job_store

        token = current_discovery_claim_token
        return unless token

        assert_analysis_worktree!
        results = completed.merge(new_results).values.sort_by { |item| item.fetch("feature_id") }
        result_ids = results.to_h { |item| [ item.fetch("feature_id"), true ] }
        checkpoint_features = features.select { |feature| result_ids[feature.id.to_s] }
        payload = build_payload(
          entry, project_root, cfg, state, checkpoint_features,
          existing_theses + new_theses,
          existing_suppressions + new_suppressions,
          reviewer,
          feature_results: results
        ).merge("complete" => false, "zero_reason" => nil)
        @durable_aggregate = @job_store.checkpoint_discovery_progress!(
          token,
          envelope: payload,
          now: @heartbeat_clock.call,
          lease_sec: @heartbeat_lease_sec
        )
      end

      def current_discovery_claim_token
        return @manual_claim_token if @manual_claim_token

        active_claim_tokens.find { |token| token.fetch(:kind) == :discovery }
      end

      def active_claim_tokens
        process_start = Hive::Lock.process_start_time(Process.pid)
        return [] if process_start.to_s.empty? || !@job_store || !@manifest

        @job_store.active_claim_tokens_for_process(
          @manifest.fetch("job_id"), pid: Process.pid,
          process_start_time: process_start
        )
      end

      def with_claim_heartbeat(job_id)
        unless job_id && pr_mode? && !@dry_run && @job_store &&
               @heartbeat_interval_sec.positive? && @heartbeat_lease_sec.positive?
          return yield
        end

        mutex = Mutex.new
        wakeup = ConditionVariable.new
        stopped = false
        failure = nil
        heartbeat = Thread.new do
          loop do
            heartbeat_active_claims
            should_stop = mutex.synchronize do
              wakeup.wait(mutex, @heartbeat_interval_sec) unless stopped
              stopped
            end
            break if should_stop
          end
        rescue Hive::RefactorPatrol::JobStore::Error => e
          mutex.synchronize { failure ||= e }
        end

        value = yield
        mutex.synchronize do
          stopped = true
          wakeup.broadcast
        end
        heartbeat.join
        raise failure if failure

        value
      ensure
        if heartbeat&.alive?
          mutex.synchronize do
            stopped = true
            wakeup.broadcast
          end
          heartbeat.join
        end
      end

      def heartbeat_active_claims
        now = @heartbeat_clock.call
        active_claim_tokens.each do |token|
          renew_claim(token, now)
        rescue Hive::RefactorPatrol::JobStore::StaleClaim
          # The action may have settled after active_claim_tokens snapshotted
          # it. Its durable transition is authoritative; keep heartbeating
          # later actions instead of converting a successful child into error.
          next
        end
      end

      def renew_claim(token, now)
        if token.fetch(:kind) == :discovery
          @job_store.renew_discovery_claim!(
            token, now: now, lease_sec: @heartbeat_lease_sec,
            claim_resolver: @heartbeat_resolver
          )
        else
          @job_store.renew_action_claim!(
            token, now: now, lease_sec: @heartbeat_lease_sec,
            claim_resolver: @heartbeat_resolver
          )
        end
      end

      def release_manual_claim(reason)
        return unless @manual_claim_token && @job_store

        @job_store.release_discovery!(
          @manual_claim_token, reason: reason, now: Time.now, backoff_sec: 60
        )
      rescue Hive::RefactorPatrol::JobStore::Error
        nil
      ensure
        @manual_claim_token = nil
      end

      def completed_feature_results
        return {} unless @durable_aggregate

        @durable_aggregate.fetch("feature_results").select { |item| item.fetch("complete") }
                          .to_h { |item| [ item.fetch("feature_id"), item ] }
      end

      def prior_theses
        return [] unless @durable_aggregate

        completed = completed_feature_results.keys
        Hive::RefactorPatrol::JobStore::DISPOSITIONS.flat_map do |name|
          @durable_aggregate.dig("dispositions", name).filter_map do |item|
            next unless completed.include?(item.fetch("feature_id"))

            Hive::RefactorPatrol::Thesis.from_h(item.fetch("thesis"))
          end
        end
      end

      def prior_suppressions
        return [] unless @durable_aggregate

        completed = completed_feature_results.keys
        @durable_aggregate.dig("dispositions", "suppressed").filter_map do |item|
          next unless completed.include?(item.fetch("feature_id"))

          {
            "id" => item.fetch("id"),
            "reason" => Array(item.fetch("reasons")).first.to_s,
            "reference" => item["reference"]
          }.compact
        end
      end

      def merged_feature_results(completed, reviewer, pending_features, new_theses)
        current = if reviewer.respond_to?(:feature_results)
          Array(reviewer.feature_results)
        else
          errors = reviewer.respond_to?(:review_errors) ? Array(reviewer.review_errors) : []
          pending_features.map do |feature|
            feature_errors = errors.select { |error| error["feature_id"].to_s == feature.id.to_s }
            {
              "feature_id" => feature.id.to_s,
              "complete" => feature_errors.empty?,
              "thesis_ids" => new_theses.select { |thesis| thesis.feature_id.to_s == feature.id.to_s }.map(&:id),
              "errors" => feature_errors
            }
          end
        end
        by_feature = current.to_h { |item| [ item["feature_id"].to_s, item ] }
        completed.merge(by_feature).values.sort_by { |item| item.fetch("feature_id") }
      end

      def bounded_review_features(pending_features, token_budget)
        return pending_features unless pr_mode?
        return [] if pending_features.empty?

        capacity = token_budget.remaining_launches(stage: Hive::RefactorPatrol::ReviewAgentRunner::STAGE)
        pending_features.first([ capacity, 1 ].max)
      end

      def lifecycle_theses(aggregate)
        Hive::RefactorPatrol::JobStore::DISPOSITIONS.flat_map do |name|
          aggregate.dig("dispositions", name).map do |item|
            Hive::RefactorPatrol::Thesis.from_h(item.fetch("thesis"))
          end
        end
      end

      def lifecycle_payload(entry, project_root, aggregate)
        {
          "schema" => "hive-refactor-patrol",
          "schema_version" => Hive::RefactorPatrol::Reporter::V2_SCHEMA_VERSION,
          "ok" => true,
          "job_id" => aggregate.fetch("job_id"),
          "project" => entry.fetch("name"),
          "project_root" => project_root,
          "dry_run" => false,
          "source_pr" => aggregate.fetch("source"),
          "analysis_sha" => aggregate.fetch("analysis_sha").to_s,
          "complete" => aggregate.fetch("complete"),
          "features_mapped" => aggregate.fetch("feature_results").size,
          "accepted" => aggregate.dig("dispositions", "accepted"),
          "flagged" => aggregate.dig("dispositions", "flagged"),
          "suppressed" => aggregate.dig("dispositions", "suppressed"),
          "review_errors" => aggregate.fetch("review_errors"),
          "feature_results" => aggregate.fetch("feature_results"),
          "zero_reason" => aggregate.fetch("zero_reason"),
          "attempts" => [],
          "actions" => aggregate.fetch("actions").map { |action| action_projection(action) }
        }
      end

      # Daemon scheduling consumes the immutable artifact already published by
      # merge intake. It never asks GitHub to reinterpret a PR number/URL.
      def load_job_manifest!(entry, project_root, cfg)
        path = File.expand_path(@job_manifest.to_s)
        root = File.expand_path(File.join(project_root, ".hive-state", "refactor_patrol", "v2", "manifests"))
        unless File.dirname(path) == root && File.file?(path)
          raise Hive::ConfigError, "refactor patrol job manifest must be a published file under #{root}"
        end

        default_branch = if @actions
          store = @job_store_factory.call(project_root)
          store.read_job(File.basename(path, ".json")).dig("source", "base_branch")
        else
          cfg["default_branch"] || Hive::GitOps.new(project_root).default_branch
        end
        Hive::RefactorPatrol::PrManifest.load!(
          path,
          expected_job_id: File.basename(path, ".json"),
          registration: entry.fetch("name"),
          default_branch: default_branch
        )
      end

      def scope_to_manifest(features)
        features.select do |feature|
          boundary = Array(feature.owned_files) + Array(feature.entrypoints) + Array(feature.tests)
          boundary.any? { |path| manifest_changed_paths.include?(path) }
        end
      end

      def changed_path?(paths, changed)
        return Array(paths).any? { |path| manifest_changed_paths.include?(path) } if pr_mode?

        !Array(changed).empty? && (Array(paths) & Array(changed)).any?
      end

      def manifest_changed_paths
        @manifest_changed_paths ||= begin
          paths = @manifest.fetch("changed_paths") + @manifest.fetch("files").filter_map { |file| file["previous_path"] }
          paths.to_set
        end
      end

      def build_v2_payload(entry, project_root, features, theses, suppressed, reviewer,
                           feature_results: nil, complete: nil)
        progress = Array(feature_results)
        errors = if progress.empty? && features.empty?
          []
        elsif feature_results
          progress.flat_map { |item| Array(item["errors"]) }
        elsif reviewer.respond_to?(:review_errors)
          Array(reviewer.review_errors)
        else
          []
        end
        completed_ids = completed_feature_results.keys
        current_theses = theses.reject { |thesis| completed_ids.include?(thesis.feature_id.to_s) }
        current_thesis_ids = current_theses.to_h { |thesis| [ thesis.id.to_s, true ] }
        current_suppressions = suppressed.select { |item| current_thesis_ids[item.fetch("id").to_s] }
        payload = @reporter.v2_envelope(
          job_id: @manifest.fetch("job_id"),
          project: entry.fetch("name"),
          project_root: project_root,
          dry_run: @dry_run,
          source_pr: source_pr_context,
          analysis_sha: @checkout_snapshot.fetch("analysis_sha"),
          features: features,
          theses: current_theses,
          suppressed: current_suppressions,
          complete: complete != false && errors.empty? && progress.all? { |item| item["complete"] == true },
          review_errors: errors,
          feature_results: progress,
          actions: [],
          attempts: []
        )
        restore_completed_dispositions!(payload, completed_ids)
        payload["zero_reason"] = final_zero_reason(features, theses, payload) if payload.fetch("complete")
        payload
      end

      def restore_completed_dispositions!(payload, completed_ids)
        return payload if completed_ids.empty? || !@durable_aggregate

        Hive::RefactorPatrol::JobStore::DISPOSITIONS.each do |name|
          current = payload.fetch(name).reject do |item|
            completed_ids.include?(item.fetch("feature_id"))
          end
          immutable = @durable_aggregate.dig("dispositions", name).select do |item|
            completed_ids.include?(item.fetch("feature_id"))
          end
          payload[name] = immutable + current
        end
        payload
      end

      def final_zero_reason(features, theses, payload)
        return nil unless payload.fetch("accepted").empty? && payload.fetch("flagged").empty?
        return "no_mapped_slice" if features.empty?
        return "no_theses" if theses.empty?
        return "all_suppressed" if payload.fetch("suppressed").size == theses.size

        nil
      end

      def build_action_payload(entry, project_root, result)
        aggregate = result.aggregate
        unless aggregate.fetch("job_id") == @manifest.fetch("job_id") &&
               aggregate.fetch("source") == source_pr_context
          raise Hive::ConfigError, "refactor patrol action job does not match its immutable manifest"
        end

        dispositions = aggregate.fetch("dispositions")
        {
          "schema" => "hive-refactor-patrol",
          "schema_version" => Hive::RefactorPatrol::Reporter::V2_SCHEMA_VERSION,
          "ok" => true,
          "job_id" => aggregate.fetch("job_id"),
          "project" => entry.fetch("name"),
          "project_root" => project_root,
          "dry_run" => @dry_run,
          "source_pr" => aggregate.fetch("source"),
          "analysis_sha" => aggregate.fetch("analysis_sha"),
          "complete" => aggregate.fetch("complete"),
          "features_mapped" => aggregate.fetch("feature_results").size,
          "accepted" => dispositions.fetch("accepted"),
          "flagged" => dispositions.fetch("flagged"),
          "suppressed" => dispositions.fetch("suppressed"),
          "review_errors" => aggregate.fetch("review_errors"),
          "feature_results" => aggregate.fetch("feature_results"),
          "zero_reason" => aggregate.fetch("zero_reason"),
          "attempts" => aggregate.fetch("attempts"),
          "actions" => aggregate.fetch("actions").map { |action| action_projection(action) },
          "action_status" => result.completeness
        }
      end

      def action_projection(action)
        action.slice(
          "canonical_action_id", "thesis_id", "thesis_fingerprint", "kind",
          "family_id", "owner_job_id", "outcome", "terminal", "receipts"
        ).compact
      end

      def pr_mode?
        !@pr.nil? || !@job_manifest.nil?
      end

      def query_mode?
        @list_jobs || !@show_job.nil?
      end

      def query_requested?
        query_mode? || !@query_limit.nil? || !@query_cursor.nil? || @query_full
      end

      def run_job_query
        entry, project_root, = resolve_project!
        query = Hive::RefactorPatrol::JobQuery.new(@job_store_factory.call(project_root))
        payload = if @list_jobs
          query.list_envelope(
            project: entry.fetch("name"), project_root: project_root,
            limit: @query_limit, cursor: @query_cursor
          )
        else
          query.show_envelope(
            project: entry.fetch("name"), project_root: project_root, job_id: @show_job,
            limit: @query_limit, full: @query_full
          )
        end
        if @json
          puts JSON.generate(payload)
        else
          puts query.text(payload)
        end
        payload
      end

      def source_pr_context
        @manifest.fetch("source").merge(
          "changed_paths" => @manifest.fetch("changed_paths"),
          "manifest_checksum" => @manifest.fetch("manifest_checksum")
        )
      end

      def pin_checkout!(project_root, cfg)
        branch = cfg["default_branch"] || Hive::GitOps.new(project_root).default_branch
        guard = @checkout_guard_factory.call(project_root, branch)
        @checkout_snapshot = guard.validate_and_snapshot!(
          merge_sha: @manifest.dig("source", "merge_sha"),
          analysis_sha: pinned_analysis_sha(project_root)
        )
      end

      def prepare_checkout_and_discovery!(entry, project_root, cfg)
        if @pr && !@dry_run
          prepare_durable_discovery!(entry, project_root, cfg)
        else
          # Scheduler job manifests are already durable/claimed, while dry
          # runs deliberately create no durable job. Both still need an exact
          # source snapshot before materialization.
          pin_checkout!(project_root, cfg)
          prepare_durable_discovery!(entry, project_root, cfg) unless @dry_run
        end
      end

      def pinned_analysis_sha(project_root)
        store = @job_store || @job_store_factory.call(project_root)
        store.read_job(@manifest.fetch("job_id"))["analysis_sha"]
      rescue Hive::RefactorPatrol::JobStore::RecordNotFound
        nil
      end

      def materialize_analysis_worktree!(project_root, cfg)
        @analysis_worktree = @analysis_worktree_factory.call(
          project_root, cfg, analysis_worktree_key
        )
        @analysis_worktree.create_detached_exact!(
          base_sha: @checkout_snapshot.fetch("analysis_sha")
        )
        assert_analysis_worktree!
        @analysis_worktree.path
      end

      def analysis_worktree_key
        job_id = @manifest.fetch("job_id")
        return job_id unless @dry_run

        @analysis_worktree_key ||= "#{job_id}-dry-run-#{Process.pid}-#{SecureRandom.hex(6)}"
      end

      def build_analysis_worktree(project_root, cfg, job_id)
        configured_root = cfg["worktree_root"] ||
                          Hive::Worktree.default_worktree_root(File.basename(project_root))
        root = File.join(File.expand_path(configured_root), ".refactor-patrol", "analysis")
        slug = job_id.to_s.gsub(/[^a-zA-Z0-9_.-]+/, "-")[0, 100]
        Hive::Worktree.new(project_root, slug, worktree_root: root)
      end

      def assert_analysis_worktree!
        raise Hive::WorktreeError, "architecture patrol analysis worktree is unavailable" unless @analysis_worktree

        @analysis_worktree.assert_detached_exact!(
          base_sha: @checkout_snapshot.fetch("analysis_sha")
        )
      end

      def cleanup_analysis_worktree!(raise_on_drift: true)
        return unless @analysis_worktree

        worktree = @analysis_worktree
        drift_error = begin
          assert_analysis_worktree!
          nil
        rescue Hive::Error => e
          e
        end
        cleanup_error = begin
          worktree.remove!(force: true)
          nil
        rescue Hive::Error => e
          e
        end
        error = drift_error || cleanup_error
        raise error if error && raise_on_drift
      ensure
        @analysis_worktree = nil
      end

      def ephemeral_discovery?
        @dry_run || pr_mode?
      end

      def emit(payload, theses)
        write_result_file(payload)
        if @json
          puts JSON.generate(payload)
        else
          puts @reporter.text(payload, theses)
        end
        payload
      end

      def emit_error(error)
        return unless @json

        payload = if query_requested?
          Hive::RefactorPatrol::JobQuery.error_envelope(
            error,
            action: @list_jobs ? "list" : (@show_job.nil? ? nil : "show")
          )
        else
          Hive::RefactorPatrol::Reporter.error_envelope(
            error,
            version: pr_mode? ? Hive::RefactorPatrol::Reporter::V2_SCHEMA_VERSION : Hive::RefactorPatrol::Reporter::V1_SCHEMA_VERSION,
            error_kind: error.is_a?(Hive::ConfigError) ? "config" : "error",
            job_id: @manifest && @manifest["job_id"],
            source_pr: @manifest && source_pr_context
          )
        end
        begin
          write_result_file(payload)
        rescue StandardError
          nil
        end
        puts JSON.generate(payload)
      end

      def validate_result_file!(project_root)
        path = File.expand_path(@result_file.to_s)
        root = File.expand_path(
          File.join(project_root, ".hive-state", "refactor_patrol", "v2", "results")
        )
        basename = File.basename(path)
        unless File.dirname(path) == root && basename.start_with?("#{@manifest.fetch('job_id')}-") &&
               basename.end_with?(".json")
          raise Hive::ConfigError, "refactor patrol result file must be a job-bound file under #{root}"
        end

        @result_file_path = path
      end

      def write_result_file(payload)
        return unless @result_file_path

        FileUtils.mkdir_p(File.dirname(@result_file_path))
        Hive::AtomicFile.write(
          @result_file_path, "#{JSON.generate(payload)}\n", mode: 0o600
        )
      end
    end
  end
end
