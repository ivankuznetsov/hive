require "json"
require "digest"
require "set"
require "time"
require "uri"
require "hive/atomic_file"
require "hive/config"
require "hive/gh"
require "hive/daemon/refactor_patrol_merge_progress_store"
require "hive/modules/migration/evidence_store"
require "hive/modules/migration/patrols"
require "hive/refactor_patrol/architecture_intake_transitions"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/github_gateway"
require "hive/refactor_patrol/policy"
require "hive/refactor_patrol/pr_manifest_resolver"

module Hive
  module Daemon
    # Durable catch-up and immediate-merge intake for architecture patrol.
    # Reconciler state is only a replayable GitHub cursor; immutable manifests
    # and JobStore aggregates remain the authoritative lifecycle records.
    class RefactorPatrolMergeReconciler
      SCHEMA = "hive-refactor-patrol-reconciler".freeze
      SCHEMA_VERSION = 2
      STATE_KEYS = %w[
        schema schema_version registration host repository default_branch high_water
        overlap_occurrences seeded_at updated_at
      ].freeze
      OCCURRENCE_KEYS = %w[merged_at pr_number merge_sha].freeze
      DEFAULT_OVERLAP_SEC = 3600
      DEFAULT_PAGE_SIZE = 100
      DEFAULT_POLL_INTERVAL_SEC = 300
      DEFAULT_TICK_BUDGET_SEC = 15.0
      DEFAULT_MAX_CALL_TIMEOUT_SEC = 5.0
      DEFAULT_BACKOFF_BASE_SEC = RefactorPatrolMergeProgressStore::DEFAULT_BACKOFF_BASE_SEC
      DEFAULT_BACKOFF_MAX_SEC = RefactorPatrolMergeProgressStore::DEFAULT_BACKOFF_MAX_SEC
      MIN_CALL_TIMEOUT_SEC = 0.01
      INGEST_DEFERRED = :deferred

      class Blocked < Hive::Error; end
      class ScanInvalidated < Hive::Error; end

      class GithubFailure < Hive::Error
        attr_reader :original

        def initialize(original)
          @original = original
          super(original.message)
          set_backtrace(original.backtrace)
        end
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     gh: Hive::Gh,
                     github_gateway: nil,
                     overlap_sec: DEFAULT_OVERLAP_SEC,
                     page_size: DEFAULT_PAGE_SIZE, resolver_factory: nil,
                     job_store_factory: nil, dry_run: false,
                     poll_interval_sec: DEFAULT_POLL_INTERVAL_SEC,
                     tick_budget_sec: DEFAULT_TICK_BUDGET_SEC,
                     max_call_timeout_sec: DEFAULT_MAX_CALL_TIMEOUT_SEC,
                     backoff_base_sec: DEFAULT_BACKOFF_BASE_SEC,
                     backoff_max_sec: DEFAULT_BACKOFF_MAX_SEC,
                     monotonic_clock: nil, jitter: nil, progress_store: nil,
                     module_event_publisher: nil, migration_snapshot: nil,
                     evidence_store_factory: nil)
        @registry = registry
        @config_loader = config_loader
        @gh = gh
        @github_gateway = Hive::RefactorPatrol::GithubGateway.coerce(
          github_gateway,
          transport: gh,
          required: %i[merged_prs_page merged_pr_details]
        )
        @overlap_sec = Integer(overlap_sec)
        @page_size = Integer(page_size)
        @poll_interval_sec = Integer(poll_interval_sec)
        raise ArgumentError, "refactor patrol merge poll interval cannot be negative" if @poll_interval_sec.negative?
        @tick_budget_sec = positive_float!(tick_budget_sec, "tick budget")
        @max_call_timeout_sec = positive_float!(max_call_timeout_sec, "per-call timeout")
        @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @progress_store = progress_store || RefactorPatrolMergeProgressStore.new(
          dry_run: dry_run, backoff_base_sec: backoff_base_sec,
          backoff_max_sec: backoff_max_sec, jitter: jitter
        )
        @resolver_factory = resolver_factory || method(:build_resolver)
        @job_store_factory = job_store_factory
        @dry_run = dry_run
        @module_event_publisher = module_event_publisher
        @migration_snapshot = migration_snapshot || lambda do |entry|
          Hive::Modules::Migration::Patrols.ownership_snapshot(
            entry.fetch("path"), "architecture-patrol",
            hive_state_path: entry["hive_state_path"]
          )
        end
        @evidence_store_factory = evidence_store_factory || lambda do |entry|
          state = entry["hive_state_path"] ||
                  File.join(entry.fetch("path"), ".hive-state")
          Hive::Modules::Migration::EvidenceStore.new(
            root: File.join(
              state, "module-runtime", "migration", "patrol-evidence"
            )
          )
        end
        @architecture_intake_transitions =
          Hive::RefactorPatrol::ArchitectureIntakeTransitions.new(
            config_loader: @config_loader,
            migration_snapshot: @migration_snapshot,
            evidence_store_factory: @evidence_store_factory,
            admission_error: Blocked
          )
        @next_poll_at = nil
        @rotation_offset = 0
      end

      # Reconcile every explicitly enabled registered project. Results are
      # structured so Dispatcher can log blocks without treating one project
      # failure as a daemon-wide tick failure.
      def tick(now: Time.now)
        return [] if @next_poll_at && now < @next_poll_at

        deadline = begin_tick_budget(now)
        prepared = []
        results = {}
        entries = rotated_entries(Array(@registry.call))
        entries.each do |entry|
          begin
            cfg = @config_loader.call(entry.fetch("path"))
            prepared << [ entry, cfg ] if intake_enabled?(cfg)
          rescue StandardError => e
            results[entry && entry["name"].to_s] = blocked_result(entry && entry["name"], e)
          end
        end

        active = prepared
        until active.empty?
          next_round = []
          active.each_with_index do |(entry, cfg), index|
            remaining = deadline - monotonic_now
            if remaining < MIN_CALL_TIMEOUT_SEC
              name = entry.fetch("name").to_s
              results[name] ||= deferred_result(name)
              next_round << [ entry, cfg ]
              next
            end

            slots = active.length - index
            timeout_sec = [ @max_call_timeout_sec, remaining / slots ].min
            result = reconcile_step(entry, cfg, now: now, timeout_sec: timeout_sec)
            results[entry.fetch("name").to_s] = result
            next_round << [ entry, cfg ] if result.fetch(:status) == :partial
          end
          break if next_round.empty? || deadline - monotonic_now < MIN_CALL_TIMEOUT_SEC

          # A project that was first in one round is last in the next. Along
          # with per-call slices, this prevents a large repository from
          # repeatedly taking the first opportunity inside the tick budget.
          active = next_round.rotate(1)
        end

        @rotation_offset = entries.empty? ? 0 : (@rotation_offset + 1) % entries.length
        ordered_results = entries.filter_map { |entry| results[entry["name"].to_s] }
        pending = ordered_results.any? { |result| %i[partial deferred].include?(result.fetch(:status)) }
        retry_times = ordered_results.filter_map { |result| result[:retry_at] }
        @next_poll_at = next_poll_at(now, pending: pending, retry_times: retry_times)
        ordered_results
      end

      # Immediate watcher adapter. Disabled/unregistered projects retain the
      # legacy archive-only path; enabled projects must durably publish both
      # manifest and queued aggregate before the watcher may archive. Returns
      # :deferred without remote work when catch-up or an earlier exact-PR
      # hydration has spent this dispatcher's shared tick deadline.
      def ingest(project:, pr:, now: Time.now)
        entry = Array(@registry.call).find { |candidate| candidate["name"] == project.to_s }
        return nil unless entry

        cfg = @config_loader.call(entry.fetch("path"))
        return nil unless intake_enabled?(cfg)

        deadline = shared_tick_deadline(now)
        identity_timeout = timeout_for_deadline(deadline)
        return INGEST_DEFERRED unless identity_timeout

        host, repository = registered_identity(
          entry.fetch("path"), cfg, timeout_sec: identity_timeout
        )
        assert_bound_identity!(
          load_state(entry.fetch("path")),
          entry.fetch("name"),
          host,
          repository,
          default_branch(cfg),
          project_root: entry.fetch("path")
        )
        timeout_sec = timeout_for_deadline(deadline)
        return INGEST_DEFERRED unless timeout_sec

        ingest_for(entry, cfg, pr: pr, expected: nil, now: now, timeout_sec: timeout_sec)
      end

      def state_path(project_root)
        File.join(
          hive_state_path_for(project_root), "refactor_patrol", "v2", "reconciler.json"
        )
      end

      def progress_path(project_root)
        @progress_store.path(project_root)
      end

      # Gives PrMergeWatcher a bounded slice of this dispatcher's shared
      # architecture-intake deadline before it starts its own gh state poll.
      # Projects without enabled architecture intake retain the watcher's
      # bounded fallback because their archive path does not consume this
      # reconciler's budget.
      def watcher_poll_timeout(project:, now:, maximum:)
        limit = positive_float!(maximum, "watcher poll timeout")
        entry = Array(@registry.call).find { |candidate| candidate["name"] == project.to_s }
        return limit unless entry

        cfg = @config_loader.call(entry.fetch("path"))
        return limit unless intake_enabled?(cfg)

        timeout = timeout_for_deadline(shared_tick_deadline(now))
        timeout && [ timeout, limit ].min
      rescue StandardError
        limit || Float(maximum)
      end

      private

      def hive_state_path_for(project_root)
        expanded = File.expand_path(project_root)
        entry = Array(@registry.call).find do |candidate|
          File.expand_path(candidate.fetch("path")) == expanded
        end
        return entry.fetch("hive_state_path") if entry && entry["hive_state_path"]

        File.join(expanded, ".hive-state")
      end

      def reconcile_step(entry, cfg, now:, timeout_sec:)
        project_root = entry.fetch("path")
        registration = entry.fetch("name")
        branch = default_branch(cfg)
        step_deadline = monotonic_now + timeout_sec
        identity_timeout = timeout_for_deadline(step_deadline)
        return deferred_result(registration) unless identity_timeout

        host, repository = registered_identity(
          project_root, cfg, timeout_sec: identity_timeout
        )
        previous = load_state(project_root)
        assert_bound_identity!(
          previous, registration, host, repository, branch,
          project_root: project_root
        )
        progress = @progress_store.load(project_root)
        @progress_store.assert_identity!(
          progress, registration: registration, host: host,
          repository: repository, default_branch: branch,
          project_root: project_root
        )
        expected_checkpoint = @progress_store.checkpoint_fingerprint(previous)
        if progress && progress.fetch("base_checkpoint_sha256") != expected_checkpoint
          @progress_store.clear(project_root)
          progress = nil
        end
        validate_progress_against_checkpoint!(progress, previous, project_root) if progress

        if progress && @progress_store.retry_pending?(progress, now)
          retry_at = Time.iso8601(progress.dig("retry", "not_before"))
          return {
            project: registration, status: :backoff,
            enqueued_prs: progress.dig("scan", "enqueued_prs") || [],
            reason: progress.dig("retry", "last_error"), retry_at: retry_at
          }
        end

        progress ||= @progress_store.build(
          registration: registration, host: host, repository: repository,
          default_branch: branch, previous: previous,
          merged_since: overlap_start(previous, now), now: now
        )
        @progress_store.write(project_root, progress)

        operation_timeout = timeout_for_deadline(step_deadline)
        return deferred_result(registration) unless operation_timeout

        case progress.dig("scan", "phase")
        when "pages"
          scan_page_step(
            entry, cfg, previous, progress, now: now,
            timeout_sec: operation_timeout
          )
        when "ingest"
          ingest_step(
            entry, cfg, previous, progress, now: now,
            timeout_sec: operation_timeout
          )
        else
          raise Blocked, "reconciler progress scan phase is invalid"
        end
      rescue GithubFailure => e
        begin
          progress && @progress_store.record_failure!(
            project_root, progress, e.original, failure_time(now)
          )
        rescue StandardError => persistence_error
          return blocked_result(
            registration,
            Blocked.new("#{e.message}; cannot persist GitHub backoff: #{persistence_error.message}")
          )
        end
        blocked_result(registration, e.original).merge(
          retry_at: progress && Time.iso8601(progress.dig("retry", "not_before"))
        )
      rescue ScanInvalidated => e
        begin
          restart_scan!(project_root, progress, now)
        rescue StandardError => persistence_error
          return blocked_result(
            registration,
            Blocked.new("#{e.message}; cannot reset invalid scan: #{persistence_error.message}")
          )
        end
        {
          project: registration, status: :partial,
          enqueued_prs: [], reason: e.message
        }
      rescue StandardError => e
        blocked_result(registration, e)
      end

      def ingest_for(entry, cfg, pr:, expected:, now:, timeout_sec:)
        resolver = @resolver_factory.call(entry, cfg, @github_gateway, @dry_run)
        manifest = resolver.resolve(pr, timeout_sec: timeout_sec)
        assert_manifest_matches!(manifest, expected) if expected
        store = job_store_for(entry)
        result = @architecture_intake_transitions.enqueue(
          entry: entry,
          store: store,
          manifest: manifest,
          policy: policy_snapshot(cfg, now),
          now: now,
          dry_run: @dry_run
        )
        @module_event_publisher&.pull_request_merged(entry, manifest) unless @dry_run
        result
      end

      def build_resolver(entry, cfg, github_gateway, dry_run)
        Hive::RefactorPatrol::PrManifestResolver.new(
          project_root: entry.fetch("path"),
          registration: entry.fetch("name"),
          default_branch: default_branch(cfg),
          cfg: cfg,
          github_gateway: github_gateway,
          dry_run: dry_run
        )
      end

      def job_store_for(entry)
        return @job_store_factory.call(entry.fetch("path")) if @job_store_factory

        Hive::RefactorPatrol::JobStore.new(
          entry.fetch("path"),
          hive_state_path: entry.fetch("hive_state_path"),
          project: entry
        )
      end

      def scan_page_step(entry, cfg, previous, progress, now:, timeout_sec:)
        scan = progress.fetch("scan")
        repository = progress.fetch("repository")
        host = progress.fetch("host")
        branch = progress.fetch("default_branch")
        cursor = scan.fetch("cursor")
        if cursor && scan.fetch("seen_cursors").include?(cursor)
          raise GithubFailure, Blocked.new("GitHub pagination cursor repeated #{cursor.inspect}")
        end

        page = begin
          value = @github_gateway.merged_prs_page(
            repository: repository,
            host: host,
            default_branch: branch,
            cursor: cursor,
            merged_since: Time.iso8601(scan.fetch("merged_since")),
            merged_until: Time.iso8601(scan.fetch("merged_until")),
            per_page: @page_size,
            worktree_path: entry.fetch("path"),
            cfg: cfg,
            timeout_sec: timeout_sec
          )
          validate_page!(value, repository, host, branch)
          value
        rescue StandardError => e
          raise GithubFailure, e
        end

        combined, next_cursor = begin
          page_items = page.fetch("items").map { |item| normalized_summary(item) }
          since_time = Time.iso8601(scan.fetch("merged_since"))
          until_time = Time.iso8601(scan.fetch("merged_until"))
          page_count = page.fetch("total_count")
          if scan["result_count"] && scan.fetch("result_count") != page_count
            raise ScanInvalidated,
                  "GitHub frozen merged-PR result count changed from " \
                  "#{scan.fetch('result_count')} to #{page_count}"
          end
          scan["result_count"] ||= page_count
          merged = dedupe_items(scan.fetch("items") + page_items).select do |item|
            merged_at = Time.iso8601(item.fetch("merged_at")).utc
            merged_at >= since_time.utc && merged_at <= until_time.utc
          end
          if page.fetch("has_next_page")
            candidate_cursor = page.fetch("next_cursor")
            if candidate_cursor.to_s.empty?
              raise Blocked, "GitHub pagination omitted next cursor"
            end
            if candidate_cursor == cursor || scan.fetch("seen_cursors").include?(candidate_cursor)
              raise Blocked, "GitHub pagination cursor repeated #{candidate_cursor.inspect}"
            end
            [ merged, candidate_cursor ]
          else
            unless merged.length == scan.fetch("result_count")
              raise ScanInvalidated,
                    "GitHub frozen merged-PR traversal returned #{merged.length} of " \
                    "#{scan.fetch('result_count')} results"
            end
            [ merged, nil ]
          end
        rescue ScanInvalidated
          raise
        rescue StandardError => e
          raise GithubFailure, e
        end

        scan["items"] = combined
        scan.fetch("seen_cursors") << cursor if cursor
        if page.fetch("has_next_page")
          scan["cursor"] = next_cursor
          progress["retry"] = nil
          @progress_store.touch!(progress, now)
          @progress_store.write(entry.fetch("path"), progress)
          return partial_result(progress)
        end

        scan["cursor"] = nil
        scan["phase"] = "ingest"
        progress["retry"] = nil
        @progress_store.touch!(progress, now)
        if previous.nil?
          finalize_scan(entry.fetch("path"), progress, previous, now: now)
        elsif scan_candidates(previous, scan).empty?
          finalize_scan(entry.fetch("path"), progress, previous, now: now)
        else
          @progress_store.write(entry.fetch("path"), progress)
          partial_result(progress)
        end
      end

      # Search indexing can change issueCount even inside a time-frozen query.
      # Restart from page one while retaining the original upper bound; moving
      # that bound during first-enable seeding could absorb a newly merged PR
      # without ever enqueueing it on the next authoritative scan.
      def restart_scan!(project_root, progress, now)
        scan = progress.fetch("scan")
        scan["phase"] = "pages"
        scan["result_count"] = nil
        scan["cursor"] = nil
        scan["items"] = []
        scan["seen_cursors"] = []
        scan["ingest_index"] = 0
        scan["enqueued_prs"] = []
        progress["retry"] = nil
        @progress_store.touch!(progress, now)
        @progress_store.write(project_root, progress)
      end

      def ingest_step(entry, cfg, previous, progress, now:, timeout_sec:)
        scan = progress.fetch("scan")
        return finalize_scan(entry.fetch("path"), progress, previous, now: now) unless previous

        candidates = scan_candidates(previous, scan)
        index = scan.fetch("ingest_index")
        return finalize_scan(entry.fetch("path"), progress, previous, now: now) if index >= candidates.length

        item = candidates.fetch(index)
        begin
          ingest_for(
            entry, cfg, pr: item.fetch("url"), expected: item, now: now,
            timeout_sec: timeout_sec
          )
        rescue Hive::GhError => e
          raise GithubFailure, e
        end
        scan["ingest_index"] = index + 1
        scan.fetch("enqueued_prs") << item.fetch("number")
        scan["enqueued_prs"].uniq!
        progress["retry"] = nil
        @progress_store.touch!(progress, now)

        if scan.fetch("ingest_index") >= candidates.length
          finalize_scan(entry.fetch("path"), progress, previous, now: now)
        else
          @progress_store.write(entry.fetch("path"), progress)
          partial_result(progress)
        end
      end

      def finalize_scan(project_root, progress, previous, now:)
        scan = progress.fetch("scan")
        items = scan.fetch("items")
        if previous.nil?
          high_water = maximum_occurrence(items)
          replacement = build_state(
            registration: progress.fetch("registration"),
            host: progress.fetch("host"),
            repository: progress.fetch("repository"),
            default_branch: progress.fetch("default_branch"),
            high_water: high_water,
            overlap_occurrences: overlap_occurrences(items, high_water),
            seeded_at: Time.iso8601(scan.fetch("started_at")),
            updated_at: now
          )
          status = :seeded
        else
          high_water = [ previous.fetch("high_water"), maximum_occurrence(items) ].compact.map do |item|
            occurrence(item)
          end.max_by do |item|
            occurrence_tuple(item)
          end
          replacement = build_state(
            registration: progress.fetch("registration"),
            host: progress.fetch("host"),
            repository: progress.fetch("repository"),
            default_branch: progress.fetch("default_branch"),
            high_water: high_water,
            overlap_occurrences: merge_overlap(
              previous.fetch("overlap_occurrences"), items, high_water
            ),
            seeded_at: Time.iso8601(previous.fetch("seeded_at")),
            updated_at: now
          )
          status = :ok
        end

        write_state(project_root, replacement) unless @dry_run
        @progress_store.clear(project_root)
        {
          project: progress.fetch("registration"), status: status,
          enqueued_prs: scan.fetch("enqueued_prs"), reason: nil
        }
      end

      def scan_candidates(previous, scan)
        seen = previous.fetch("overlap_occurrences").to_set { |item| occurrence_key(item) }
        scan.fetch("items").reject { |item| seen.include?(occurrence_key(item)) }
            .sort_by { |item| occurrence_tuple(item) }
      end

      def partial_result(progress)
        {
          project: progress.fetch("registration"), status: :partial,
          enqueued_prs: progress.dig("scan", "enqueued_prs") || [], reason: nil
        }
      end

      def validate_page!(page, repository, host, branch)
        unless page.is_a?(Hash) && page["complete"] == true && page["items"].is_a?(Array) &&
               [ true, false ].include?(page["has_next_page"]) &&
               page["total_count"].is_a?(Integer) && page["total_count"] >= 0 &&
               page["items"].length <= page["total_count"]
          raise Blocked, "GitHub merged-PR page is incomplete"
        end

        page.fetch("items").each do |item|
          raise Blocked, "GitHub merged-PR item is not an object" unless item.is_a?(Hash)

          %w[number url repository base_branch merge_sha merged_at].each do |key|
            value = item[key]
            unless key == "number" || (value.is_a?(String) && !value.empty?)
              raise Blocked, "GitHub merged-PR item is missing #{key}"
            end
          end
          unless item.fetch("number").is_a?(Integer) && item.fetch("number").positive?
            raise Blocked, "GitHub merged-PR item has invalid number"
          end
          unless item.fetch("merge_sha").match?(/\A[a-f0-9]{40,64}\z/)
            raise Blocked, "GitHub merged-PR item has invalid merge SHA"
          end
          Time.iso8601(item.fetch("merged_at"))
          raise Blocked, "GitHub merged-PR repository changed within page" unless canonical_repository(item.fetch("repository")) == repository
          item_host = URI.parse(item.fetch("url")).host.to_s.downcase
          raise Blocked, "GitHub merged-PR host changed within page" unless item_host == host
          raise Blocked, "GitHub merged-PR base branch changed within page" unless item.fetch("base_branch") == branch
        end
      rescue ArgumentError, TypeError, URI::InvalidURIError => e
        raise Blocked, "GitHub merged-PR timestamp is invalid (#{e.message})"
      end

      def dedupe_items(items)
        indexed = {}
        items.each do |item|
          key = [ canonical_repository(item.fetch("repository")), item.fetch("number"), item.fetch("merge_sha") ]
          if indexed.key?(key) && indexed.fetch(key) != item
            raise Blocked, "GitHub pagination returned divergent payloads for PR #{item.fetch('number')}"
          end
          indexed[key] = item
        end
        indexed.values
      end

      def assert_manifest_matches!(manifest, expected)
        source = manifest.fetch("source")
        checks = {
          "number" => expected.fetch("number"),
          "repository" => expected.fetch("repository"),
          "base_branch" => expected.fetch("base_branch"),
          "merge_sha" => expected.fetch("merge_sha"),
          "merged_at" => expected.fetch("merged_at")
        }
        actual = source.slice(*checks.keys)
        actual["repository"] = canonical_repository(actual.fetch("repository"))
        checks["repository"] = canonical_repository(checks.fetch("repository"))
        actual["merged_at"] = normalize_timestamp(actual.fetch("merged_at"))
        checks["merged_at"] = normalize_timestamp(checks.fetch("merged_at"))
        return if actual == checks

        raise Blocked, "merged-PR summary conflicts with immutable manifest for PR #{expected.fetch('number')}"
      end

      def intake_enabled?(cfg)
        cfg.dig("daemon", "enabled") == true && cfg.dig("refactor_patrol", "enabled") == true
      end

      def default_branch(cfg)
        branch = cfg["default_branch"].to_s
        raise Blocked, "refactor patrol catch-up requires an explicit default branch" if branch.empty?

        branch
      end

      def policy_snapshot(cfg, now)
        Hive::RefactorPatrol::Policy.capture(cfg, now: now)
      end

      def load_state(project_root)
        path = state_path(project_root)
        return nil unless File.file?(path)

        raw = File.binread(path)
        data = JSON.parse(raw)
        raise Blocked, "reconciler checkpoint must be an object" unless data.is_a?(Hash)
        raise Blocked, "unexpected reconciler checkpoint schema" unless data["schema"] == SCHEMA
        raise Blocked, "unsupported reconciler checkpoint schema version #{data['schema_version'].inspect}" unless data["schema_version"] == SCHEMA_VERSION
        raise Blocked, "reconciler checkpoint keys are invalid" unless data.keys.sort == STATE_KEYS.sort
        %w[registration host repository default_branch seeded_at updated_at].each do |key|
          raise Blocked, "reconciler checkpoint #{key} is missing" if data[key].to_s.empty?
        end
        Time.iso8601(data.fetch("seeded_at"))
        Time.iso8601(data.fetch("updated_at"))
        validate_occurrence!(data.fetch("high_water")) if data.fetch("high_water")
        unless data.fetch("overlap_occurrences").is_a?(Array)
          raise Blocked, "reconciler overlap occurrences must be an array"
        end
        data.fetch("overlap_occurrences").each { |item| validate_occurrence!(item) }
        data
      rescue Blocked => e
        quarantine_reconciler_state!(project_root, raw.to_s, reason: e.message)
        raise
      rescue JSON::ParserError, SystemCallError, IOError, ArgumentError, TypeError => e
        quarantine_reconciler_state!(project_root, raw.to_s, reason: "#{e.class}: #{e.message}")
        raise Blocked, "cannot read reconciler checkpoint (#{e.class}: #{e.message})"
      end

      def validate_progress_against_checkpoint!(progress, previous, project_root)
        scan = progress.fetch("scan")
        expected_since = overlap_start(previous, Time.iso8601(scan.fetch("started_at"))).utc.iso8601
        raise Blocked, "reconciler progress overlap window is invalid" unless scan.fetch("merged_since") == expected_since
        unless scan.fetch("merged_until") == scan.fetch("started_at")
          raise Blocked, "reconciler progress upper bound is invalid"
        end

        unique_items = dedupe_items(scan.fetch("items"))
        unless unique_items.length == scan.fetch("items").length
          raise Blocked, "reconciler progress contains duplicate merged-PR items"
        end
        if scan.fetch("phase") == "pages"
          unless scan.fetch("ingest_index").zero? && scan.fetch("enqueued_prs").empty?
            raise Blocked, "reconciler progress advanced intake before pagination completed"
          end
          if scan.fetch("cursor") && scan.fetch("result_count").nil?
            raise Blocked, "reconciler progress cursor is missing its frozen result count"
          end
          return
        end

        raise Blocked, "reconciler progress intake retained a pagination cursor" if scan.fetch("cursor")
        unless scan.fetch("result_count") == scan.fetch("items").length
          raise Blocked, "reconciler progress intake result count is inconsistent"
        end
        candidates = previous ? scan_candidates(previous, scan) : []
        index = scan.fetch("ingest_index")
        if index > candidates.length || scan.fetch("enqueued_prs") != candidates.first(index).map { |item| item.fetch("number") }.uniq
          raise Blocked, "reconciler progress intake checkpoint is inconsistent"
        end
      rescue Blocked => e
        @progress_store.quarantine(project_root, JSON.generate(progress), reason: e.message)
        raise
      end

      def validate_occurrence!(item)
        unless item.is_a?(Hash) && item.keys.sort == OCCURRENCE_KEYS.sort &&
               item["pr_number"].is_a?(Integer) && item["pr_number"].positive? &&
               item["merged_at"].is_a?(String) &&
               item["merge_sha"].is_a?(String) &&
               item["merge_sha"].match?(/\A[a-f0-9]{40,64}\z/)
          raise Blocked, "reconciler occurrence is invalid"
        end
        Time.iso8601(item.fetch("merged_at"))
      end

      def write_state(project_root, state)
        path = state_path(project_root)
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(state)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def build_state(registration:, host:, repository:, default_branch:, high_water:,
                      overlap_occurrences:, seeded_at:, updated_at:)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "registration" => registration,
          "host" => host,
          "repository" => repository,
          "default_branch" => default_branch,
          "high_water" => high_water,
          "overlap_occurrences" => overlap_occurrences,
          "seeded_at" => seeded_at.utc.iso8601,
          "updated_at" => updated_at.utc.iso8601
        }
      end

      def assert_bound_identity!(state, registration, host, repository, branch, project_root:)
        return unless state

        reason = if state.fetch("registration") != registration
          "registration identity changed from #{state.fetch('registration')} to #{registration}"
        elsif state.fetch("host") != host
          "repository host changed from #{state.fetch('host')} to #{host}"
        elsif state.fetch("repository") != repository
          "repository identity changed from #{state.fetch('repository')} to #{repository}"
        elsif state.fetch("default_branch") != branch
          "default branch changed from #{state.fetch('default_branch')} to #{branch}"
        end
        return unless reason

        quarantine_reconciler_state!(
          project_root,
          JSON.generate(state),
          reason: reason,
          observed: {
            "registration" => registration,
            "host" => host,
            "repository" => repository,
            "default_branch" => branch
          }
        )
        raise Blocked, reason
      end

      def occurrence(item)
        {
          "merged_at" => normalize_timestamp(item.fetch("merged_at")),
          "pr_number" => item.fetch("number", item["pr_number"]),
          "merge_sha" => item.fetch("merge_sha")
        }
      end

      def occurrence_tuple(item)
        value = item.key?("number") ? occurrence(item) : item
        [ Time.iso8601(value.fetch("merged_at")).utc, value.fetch("pr_number"), value.fetch("merge_sha") ]
      end

      def occurrence_key(item)
        occurrence_tuple(item).join("\0")
      end

      def maximum_occurrence(items)
        item = items.max_by { |candidate| occurrence_tuple(candidate) }
        item && occurrence(item)
      end

      def overlap_start(state, now)
        return now - @overlap_sec unless state
        return Time.iso8601(state.fetch("seeded_at")) - @overlap_sec unless state.fetch("high_water")

        Time.iso8601(state.dig("high_water", "merged_at")) - @overlap_sec
      end

      def overlap_occurrences(items, high_water)
        return [] unless high_water

        cutoff = Time.iso8601(high_water.fetch("merged_at")) - @overlap_sec
        items.select { |item| Time.iso8601(item.fetch("merged_at")) >= cutoff }
             .map { |item| occurrence(item) }
             .uniq
             .sort_by { |item| occurrence_tuple(item) }
      end

      def merge_overlap(previous, items, high_water)
        all = previous + items.map { |item| occurrence(item) }
        return [] unless high_water

        cutoff = Time.iso8601(high_water.fetch("merged_at")) - @overlap_sec
        all.select { |item| Time.iso8601(item.fetch("merged_at")) >= cutoff }
           .uniq { |item| occurrence_key(item) }
           .sort_by { |item| occurrence_tuple(item) }
      end

      def canonical_repository(repository)
        value = repository.to_s.strip.downcase
        raise Blocked, "registered GitHub repository identity is blank" if value.empty?

        value
      end

      def registered_identity(project_root, cfg, timeout_sec: nil)
        identity = @gh.repository_identity(
          project_root, cfg: cfg, timeout_sec: timeout_sec
        )
        host = identity.fetch("host").to_s.downcase
        raise Blocked, "registered GitHub host identity is blank" if host.empty?

        [ host, canonical_repository(identity.fetch("repository")) ]
      rescue Hive::GhError, KeyError => e
        raise Blocked, "registered GitHub repository identity is unavailable (#{e.message})"
      end

      def normalize_timestamp(value)
        Time.iso8601(value.to_s).utc.iso8601
      end

      def normalized_summary(item)
        item.merge(
          "repository" => canonical_repository(item.fetch("repository")),
          "merged_at" => normalize_timestamp(item.fetch("merged_at"))
        )
      end

      def quarantine_reconciler_state!(project_root, authoritative_bytes, reason:, observed: nil)
        return if @dry_run

        directory = File.join(
          project_root,
          ".hive-state",
          "refactor_patrol",
          "v2",
          "quarantine",
          "reconciler"
        )
        fingerprint = ::Digest::SHA256.hexdigest([ authoritative_bytes, reason, JSON.generate(observed) ].join("\0"))
        path = File.join(directory, "#{fingerprint}.json")
        return path if File.file?(path)

        evidence = {
          "schema" => "hive-refactor-patrol-reconciler-conflict",
          "schema_version" => 1,
          "reason" => reason,
          "authoritative_state_sha256" => ::Digest::SHA256.hexdigest(authoritative_bytes),
          "observed" => observed
        }
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(evidence)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(directory)
        path
      end

      def rotated_entries(entries)
        return [] if entries.empty?

        entries.rotate(@rotation_offset % entries.length)
      end

      def begin_tick_budget(now)
        started = monotonic_now
        @tick_budget_wall_time = now
        @tick_budget_started_at = started
        @tick_budget_deadline = started + @tick_budget_sec
      end

      # Catch-up runs immediately before PrMergeWatcher in Dispatcher and both
      # receive the same wall-clock `now`. Reusing that tick's absolute
      # deadline keeps N exact-PR hydrations from each receiving a fresh
      # per-call timeout after catch-up has already spent the daemon budget.
      def shared_tick_deadline(now)
        return @tick_budget_deadline if @tick_budget_deadline && @tick_budget_wall_time == now

        begin_tick_budget(now)
      end

      def timeout_for_deadline(deadline)
        remaining = deadline - monotonic_now
        return nil if remaining < MIN_CALL_TIMEOUT_SEC

        [ @max_call_timeout_sec, remaining ].min
      end

      # `now` is captured at Dispatcher tick start. Persisting retry time from
      # that stale wall value can make a slow first failure's backoff expire
      # before the call returns, so translate monotonic elapsed time back onto
      # the injected wall-clock anchor.
      def failure_time(now)
        return now unless @tick_budget_wall_time == now && @tick_budget_started_at

        elapsed = monotonic_now - @tick_budget_started_at
        return now unless elapsed.finite? && elapsed.positive?

        now + elapsed
      end

      def next_poll_at(now, pending:, retry_times:)
        return now if pending

        normal = now + @poll_interval_sec
        retry_times.compact.min.then { |retry_at| retry_at && retry_at < normal ? retry_at : normal }
      end

      def deferred_result(project)
        {
          project: project.to_s, status: :deferred, enqueued_prs: [],
          reason: "refactor patrol merge tick deadline reached"
        }
      end

      def positive_float!(value, label)
        number = Float(value)
        unless number.finite? && number.positive?
          raise ArgumentError, "refactor patrol merge #{label} must be positive"
        end

        number
      rescue TypeError, ArgumentError
        raise ArgumentError, "refactor patrol merge #{label} must be positive"
      end

      def monotonic_now
        Float(@monotonic_clock.call)
      end

      def blocked_result(project, error)
        { project: project.to_s, status: :blocked, enqueued_prs: [], reason: "#{error.class}: #{error.message}" }
      end
    end
  end
end
