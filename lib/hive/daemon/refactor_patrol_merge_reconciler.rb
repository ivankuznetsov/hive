require "json"
require "digest"
require "set"
require "time"
require "hive/atomic_file"
require "hive/config"
require "hive/gh"
require "hive/refactor_patrol/job_store"
require "hive/refactor_patrol/policy"
require "hive/refactor_patrol/pr_manifest_resolver"

module Hive
  module Daemon
    # Durable catch-up and immediate-merge intake for architecture patrol.
    # Reconciler state is only a replayable GitHub cursor; immutable manifests
    # and JobStore aggregates remain the authoritative lifecycle records.
    class RefactorPatrolMergeReconciler
      SCHEMA = "hive-refactor-patrol-reconciler".freeze
      SCHEMA_VERSION = 1
      STATE_KEYS = %w[
        schema schema_version registration repository default_branch high_water
        overlap_occurrences seeded_at updated_at
      ].freeze
      OCCURRENCE_KEYS = %w[merged_at pr_number merge_sha].freeze
      DEFAULT_OVERLAP_SEC = 3600
      DEFAULT_PAGE_SIZE = 100
      DEFAULT_POLL_INTERVAL_SEC = 300

      class Blocked < Hive::Error; end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     gh: Hive::Gh, overlap_sec: DEFAULT_OVERLAP_SEC,
                     page_size: DEFAULT_PAGE_SIZE, resolver_factory: nil,
                     job_store_factory: nil, dry_run: false,
                     poll_interval_sec: DEFAULT_POLL_INTERVAL_SEC)
        @registry = registry
        @config_loader = config_loader
        @gh = gh
        @overlap_sec = Integer(overlap_sec)
        @page_size = Integer(page_size)
        @poll_interval_sec = Integer(poll_interval_sec)
        raise ArgumentError, "refactor patrol merge poll interval cannot be negative" if @poll_interval_sec.negative?
        @resolver_factory = resolver_factory || method(:build_resolver)
        @job_store_factory = job_store_factory || ->(root) { Hive::RefactorPatrol::JobStore.new(root) }
        @dry_run = dry_run
        @next_poll_at = nil
      end

      # Reconcile every explicitly enabled registered project. Results are
      # structured so Dispatcher can log blocks without treating one project
      # failure as a daemon-wide tick failure.
      def tick(now: Time.now)
        return [] if @next_poll_at && now < @next_poll_at

        @next_poll_at = now + @poll_interval_sec
        Array(@registry.call).filter_map do |entry|
          cfg = @config_loader.call(entry.fetch("path"))
          next unless intake_enabled?(cfg)

          reconcile(entry, cfg, now: now)
        rescue StandardError => e
          blocked_result(entry && entry["name"], e)
        end
      end

      # Immediate watcher adapter. Disabled/unregistered projects retain the
      # legacy archive-only path; enabled projects must durably publish both
      # manifest and queued aggregate before the watcher may archive.
      def ingest(project:, pr:, now: Time.now)
        entry = Array(@registry.call).find { |candidate| candidate["name"] == project.to_s }
        return nil unless entry

        cfg = @config_loader.call(entry.fetch("path"))
        return nil unless intake_enabled?(cfg)

        repository = canonical_repository(@gh.repo_name_with_owner(entry.fetch("path"), cfg: cfg))
        assert_bound_identity!(
          load_state(entry.fetch("path")),
          entry.fetch("name"),
          repository,
          default_branch(cfg),
          project_root: entry.fetch("path")
        )
        ingest_for(entry, cfg, pr: pr, expected: nil, now: now)
      end

      def state_path(project_root)
        File.join(project_root, ".hive-state", "refactor_patrol", "v2", "reconciler.json")
      end

      private

      def reconcile(entry, cfg, now:)
        project_root = entry.fetch("path")
        registration = entry.fetch("name")
        branch = default_branch(cfg)
        repository = canonical_repository(@gh.repo_name_with_owner(project_root, cfg: cfg))
        previous = load_state(project_root)
        assert_bound_identity!(previous, registration, repository, branch, project_root: project_root)

        items = fetch_all(repository, branch, previous, project_root, cfg, now)
        if previous.nil?
          high_water = maximum_occurrence(items)
          seeded = build_state(
            registration: registration,
            repository: repository,
            default_branch: branch,
            high_water: high_water,
            overlap_occurrences: overlap_occurrences(items, high_water),
            seeded_at: now,
            updated_at: now
          )
          write_state(project_root, seeded) unless @dry_run
          return { project: registration, status: :seeded, enqueued_prs: [], reason: nil }
        end

        seen = previous.fetch("overlap_occurrences").to_set { |item| occurrence_key(item) }
        candidates = items.reject { |item| seen.include?(occurrence_key(item)) }
                          .sort_by { |item| occurrence_tuple(item) }
        enqueued = []
        candidates.each do |item|
          ingest_for(entry, cfg, pr: item.fetch("url"), expected: item, now: now)
          enqueued << item.fetch("number")
        end

        high_water = [ previous.fetch("high_water"), maximum_occurrence(items) ].compact.map do |item|
          occurrence(item)
        end.max_by do |item|
          occurrence_tuple(item)
        end
        overlap = merge_overlap(previous.fetch("overlap_occurrences"), items, high_water)
        replacement = build_state(
          registration: registration,
          repository: repository,
          default_branch: branch,
          high_water: high_water,
          overlap_occurrences: overlap,
          seeded_at: Time.iso8601(previous.fetch("seeded_at")),
          updated_at: now
        )
        write_state(project_root, replacement) unless @dry_run
        { project: registration, status: :ok, enqueued_prs: enqueued, reason: nil }
      rescue StandardError => e
        blocked_result(registration, e)
      end

      def ingest_for(entry, cfg, pr:, expected:, now:)
        resolver = @resolver_factory.call(entry, cfg, @gh, @dry_run)
        manifest = resolver.resolve(pr)
        assert_manifest_matches!(manifest, expected) if expected
        @job_store_factory.call(entry.fetch("path")).enqueue_manifest!(
          manifest,
          policy: policy_snapshot(cfg, now),
          now: now,
          dry_run: @dry_run
        )
      end

      def build_resolver(entry, cfg, gh, dry_run)
        Hive::RefactorPatrol::PrManifestResolver.new(
          project_root: entry.fetch("path"),
          registration: entry.fetch("name"),
          default_branch: default_branch(cfg),
          cfg: cfg,
          gh: gh,
          dry_run: dry_run
        )
      end

      def fetch_all(repository, branch, state, project_root, cfg, now)
        cursor = nil
        seen_cursors = Set.new
        items = []
        since_time = overlap_start(state, now)
        loop do
          raise Blocked, "GitHub pagination cursor repeated #{cursor.inspect}" if cursor && !seen_cursors.add?(cursor)

          page = @gh.merged_prs_page(
            repository: repository,
            default_branch: branch,
            cursor: cursor,
            merged_since: since_time,
            per_page: @page_size,
            worktree_path: project_root,
            cfg: cfg
          )
          validate_page!(page, repository, branch)
          items.concat(page.fetch("items").map { |item| normalized_summary(item) })
          break unless page.fetch("has_next_page")

          cursor = page.fetch("next_cursor")
          raise Blocked, "GitHub pagination omitted next cursor" if cursor.to_s.empty?
        end
        dedupe_items(items).select do |item|
          since_time.nil? || Time.iso8601(item.fetch("merged_at")).utc >= since_time.utc
        end
      end

      def validate_page!(page, repository, branch)
        unless page.is_a?(Hash) && page["complete"] == true && page["items"].is_a?(Array) &&
               [ true, false ].include?(page["has_next_page"])
          raise Blocked, "GitHub merged-PR page is incomplete"
        end

        page.fetch("items").each do |item|
          raise Blocked, "GitHub merged-PR item is not an object" unless item.is_a?(Hash)

          %w[number url repository base_branch merge_sha merged_at].each do |key|
            raise Blocked, "GitHub merged-PR item is missing #{key}" if item[key].nil? || item[key].to_s.empty?
          end
          unless item.fetch("number").is_a?(Integer) && item.fetch("number").positive?
            raise Blocked, "GitHub merged-PR item has invalid number"
          end
          Time.iso8601(item.fetch("merged_at"))
          raise Blocked, "GitHub merged-PR repository changed within page" unless canonical_repository(item.fetch("repository")) == repository
          raise Blocked, "GitHub merged-PR base branch changed within page" unless item.fetch("base_branch") == branch
        end
      rescue ArgumentError => e
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
        %w[registration repository default_branch seeded_at updated_at].each do |key|
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
      rescue JSON::ParserError, SystemCallError, IOError, ArgumentError => e
        quarantine_reconciler_state!(project_root, raw.to_s, reason: "#{e.class}: #{e.message}")
        raise Blocked, "cannot read reconciler checkpoint (#{e.class}: #{e.message})"
      end

      def validate_occurrence!(item)
        unless item.is_a?(Hash) && item.keys.sort == OCCURRENCE_KEYS.sort &&
               item["pr_number"].is_a?(Integer) && item["pr_number"].positive? &&
               !item["merge_sha"].to_s.empty?
          raise Blocked, "reconciler occurrence is invalid"
        end
        Time.iso8601(item.fetch("merged_at"))
      end

      def write_state(project_root, state)
        path = state_path(project_root)
        Hive::AtomicFile.write(path, "#{JSON.pretty_generate(state)}\n", mode: 0o600)
        fsync_directory(File.dirname(path))
      end

      def fsync_directory(path)
        File.open(path, File::RDONLY) { |directory| directory.fsync }
      rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
        nil
      end

      def build_state(registration:, repository:, default_branch:, high_water:,
                      overlap_occurrences:, seeded_at:, updated_at:)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "registration" => registration,
          "repository" => repository,
          "default_branch" => default_branch,
          "high_water" => high_water,
          "overlap_occurrences" => overlap_occurrences,
          "seeded_at" => seeded_at.utc.iso8601,
          "updated_at" => updated_at.utc.iso8601
        }
      end

      def assert_bound_identity!(state, registration, repository, branch, project_root:)
        return unless state

        reason = if state.fetch("registration") != registration
          "registration identity changed from #{state.fetch('registration')} to #{registration}"
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
        fsync_directory(directory)
        path
      end

      def blocked_result(project, error)
        { project: project.to_s, status: :blocked, enqueued_prs: [], reason: "#{error.class}: #{error.message}" }
      end
    end
  end
end
