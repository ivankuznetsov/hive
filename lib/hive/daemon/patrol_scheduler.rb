require "json"
require "open3"
require "shellwords"
require "time"
require "hive/config"
require "hive/git_ops"
require "hive/daemon/pr_merge_watcher"
require "hive/refactor_patrol/capability_probe"
require "hive/refactor_patrol/checkout_guard"
require "hive/refactor_patrol/local_merge_catalog"
require "hive/refactor_patrol/post_merge_scope"
require "hive/refactor_patrol/post_merge_state_store"
require "hive/refactor_patrol/state_store"

module Hive
  module Daemon
    # Slow-cadence collaborator that decides which registered projects
    # should receive one `hive patrol PROJECT --json` scan cycle. It only
    # returns dispatch hashes; Dispatcher still owns daemon.enabled,
    # legacy-layout, dry-run, and concurrency gates before spawning.
    class PatrolScheduler
      PATROL_STAGE = "patrol".freeze
      PATROL_SLUG = "patrol".freeze
      ARCHITECTURE_STAGE = "refactor-patrol-post-merge".freeze
      ARCHITECTURE_SLUG_PREFIX = "refactor-patrol-pr".freeze
      CAPABILITY_MERGE_SHA = "d98e50a5".freeze

      class GitHelper
        def default_branch(project_root, cfg:)
          cfg["default_branch"] || Hive::GitOps.new(project_root).detect_default_branch
        end

        def rev_parse(project_root, ref)
          out, err, status = Open3.capture3("git", "-C", project_root, "rev-parse", ref)
          raise Hive::GitError, "git rev-parse #{ref} failed: #{err.strip.empty? ? out : err}" unless status.success?

          out.strip
        end

        def ancestor?(project_root, ancestor, descendant)
          Hive::GitOps.new(project_root).ancestor?(ancestor, descendant)
        end
      end

      def initialize(registry: -> { Hive::Config.registered_projects },
                     config_loader: ->(path) { Hive::Config.load(path) },
                     git: GitHelper.new,
                     architecture_store_factory: nil,
                     checkout_guard_factory: nil,
                     capability_probe_factory: nil,
                     merge_catalog_factory: nil,
                     scope_factory: nil,
                     fingerprint_loader: nil,
                     architecture_completion: nil,
                     dry_run: false)
        @registry = registry
        @config_loader = config_loader
        @git = git
        @architecture_store_factory = architecture_store_factory || lambda do |entry|
          Hive::RefactorPatrol::PostMergeStateStore.new(entry.fetch("path"), project: entry.fetch("name"))
        end
        @checkout_guard_factory = checkout_guard_factory || lambda do |entry, cfg|
          Hive::RefactorPatrol::CheckoutGuard.new(entry.fetch("path"), default_branch: cfg["default_branch"])
        end
        @capability_probe_factory = capability_probe_factory || ->(_entry, _cfg) { Hive::RefactorPatrol::CapabilityProbe.new }
        @merge_catalog_factory = merge_catalog_factory || lambda do |entry|
          Hive::RefactorPatrol::LocalMergeCatalog.new(entry.fetch("path"))
        end
        @scope_factory = scope_factory || lambda do |entry, cfg|
          Hive::RefactorPatrol::PostMergeScope.new(entry.fetch("path"), cfg: cfg)
        end
        @fingerprint_loader = fingerprint_loader || lambda do |root|
          Hive::RefactorPatrol::StateStore.new(root).fingerprints
        end
        @architecture_completion = architecture_completion
        @dry_run = dry_run
        @pending = {}
        @architecture_pending = {}
        @failures = {}
        @next_check_at = {}
        @dry_batches = {}
        @last_events = []
      end

      attr_reader :last_events

      def tick(now: Time.now)
        dispatches = []
        @registry.call.each do |entry|
          project = entry.fetch("name")
          ordinary_eligible = !pending?(project) && !backed_off?(project, now) && !throttled?(project, now)
          architecture_active = architecture_batch_active?(entry)
          next unless ordinary_eligible || architecture_active

          cfg = @config_loader.call(entry.fetch("path"))
          patrol = cfg.fetch("patrol", {})
          due_now = false
          if ordinary_eligible
            # Throttle every project evaluated by the normal cadence,
            # including opted-out projects. An already-open architecture
            # batch bypasses this slow check only to drain its pinned work.
            @next_check_at[project] = now + patrol.fetch("poll_interval_sec", 600).to_i
            if patrol["enabled"] == true && due?(entry, cfg, patrol, now)
              due_now = true
              @pending[project] = { started_at: now }
              dispatches << dispatch_for(entry)
            end
          end

          next unless patrol["enabled"] == true
          next unless cfg.dig("refactor_patrol", "enabled") == true

          seed_architecture_batch(entry, cfg, now: now) if due_now
          next if pending?(project) # ordinary patrol owns first priority
          next if architecture_pending?(project)
          next unless due_now || architecture_batch_active?(entry)

          architecture = prepare_architecture_dispatch(entry, cfg, now: now)
          dispatches << architecture if architecture
        rescue Hive::ConfigError, Hive::GitError, KeyError, Hive::RefactorPatrol::PostMergeStateStore::StateError => e
          record_event(:blocked, project: project, reason: "architecture_state_unavailable",
                       evidence: { "error" => e.message })
          next
        end
        dispatches
      end

      def complete(project:, exit_code:, now: Time.now, stage: PATROL_STAGE, slug: nil, envelope: nil)
        if stage == ARCHITECTURE_STAGE
          complete_architecture(project: project, slug: slug, exit_code: exit_code,
                                envelope: envelope, now: now)
          return
        end

        @pending.delete(project)
        if exit_code.to_i.zero?
          @failures.delete(project)
        else
          count = @failures.dig(project, :count).to_i + 1
          interval = PrMergeWatcher::GH_BACKOFF_SCHEDULE[
            [ count - 1, PrMergeWatcher::GH_BACKOFF_SCHEDULE.size - 1 ].min
          ]
          @failures[project] = { count: count, next_eligible_at: now + interval }
        end
      end

      # Release a project the Dispatcher marked pending in `tick` but
      # then gated (daemon-disabled, legacy layout, or concurrency cap)
      # before spawning. Clearing the pending marker lets the next
      # eligible tick re-evaluate it; without this the project stays
      # pending forever and is never patrolled again until daemon restart
      # (the gated paths never reach `complete`, which is the only other
      # thing that clears `@pending`). No failure is recorded — the scan
      # never ran, so there is nothing to back off from. Genuine spawn
      # *errors* go through `complete` with a non-zero exit instead.
      def cancel(project:, stage: nil, slug: nil, reason: "dispatch_cancelled", now: Time.now)
        if stage == ARCHITECTURE_STAGE || (slug && slug.start_with?(ARCHITECTURE_SLUG_PREFIX))
          cancel_architecture(project, slug: slug, reason: reason, now: now)
          return
        end

        @pending.delete(project)
      end

      def pending?(project)
        @pending.key?(project)
      end

      def architecture_pending?(project)
        @architecture_pending.key?(project)
      end

      def drain_events
        events = @last_events
        @last_events = []
        events
      end

      private

      def backed_off?(project, now)
        deadline = @failures.dig(project, :next_eligible_at)
        deadline && now < deadline
      end

      def throttled?(project, now)
        return false if @failures.key?(project)

        deadline = @next_check_at[project]
        deadline && now < deadline
      end

      def due?(entry, cfg, patrol, now)
        state = read_state(entry.fetch("path"))
        case patrol.fetch("trigger", "continuous")
        when "timer"
          timer_due?(state, patrol, now)
        when "continuous"
          default_branch_changed?(entry, cfg, state) || timer_due?(state, patrol, now)
        else
          default_branch_changed?(entry, cfg, state)
        end
      end

      def timer_due?(state, patrol, now)
        last = parse_time(state["last_run_at"])
        last.nil? || (now - last) >= patrol.fetch("poll_interval_sec", 600)
      end

      def default_branch_changed?(entry, cfg, state)
        branch = @git.default_branch(entry.fetch("path"), cfg: cfg)
        current = @git.rev_parse(entry.fetch("path"), branch)
        current != state["last_scanned_sha"]
      end

      def read_state(project_root)
        path = File.join(project_root, ".hive-state", "patrol", "state.json")
        return {} unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def parse_time(value)
        value && Time.parse(value)
      rescue ArgumentError
        nil
      end

      def architecture_batch_active?(entry)
        return @dry_batches.key?(entry.fetch("name")) if @dry_run

        store = @architecture_store_factory.call(entry)
        store.initialized? && store.active_batch?
      rescue Hive::Error, SystemCallError, KeyError
        false
      end

      def seed_architecture_batch(entry, cfg, now:)
        store = @architecture_store_factory.call(entry)
        store.reopen_blocked!(now: now) if store.initialized? && !@dry_run
        with_checkout(entry, cfg) do |guard, snapshot, capability|
          if @dry_run
            seed_dry_batch(entry, store, snapshot, now: now)
          elsif !store.initialized?
            store.initialize_at!(
              head_sha: snapshot.head_sha,
              now: now,
              capability_merge_sha: CAPABILITY_MERGE_SHA,
              capability_merge_ancestor: soft_capability_ancestor(entry, snapshot)
            )
          else
            doc = store.load!(
              head_sha: snapshot.head_sha,
              ancestor_check: ->(checkpoint, head) { @git.ancestor?(entry.fetch("path"), checkpoint, head) }
            )
            catalog = @merge_catalog_factory.call(entry).discover(
              checkpoint_sha: doc.fetch("checkpoint_sha"),
              head_sha: snapshot.head_sha
            )
            store.open_batch!(
              head_sha: snapshot.head_sha,
              merges: catalog.merges,
              diagnostics: catalog.diagnostics,
              now: now
            )
          end
          record_event(:architecture_batch_opened, project: entry.fetch("name"),
                                                     reason: "normal_patrol_due",
                                                     evidence: { "head" => snapshot.head_sha,
                                                                 "executable" => capability.executable })
          guard.assert_unchanged!(snapshot)
        end
      rescue Hive::RefactorPatrol::CheckoutGuard::Blocked => e
        block_first_owed(entry, reason: e.reason, evidence: e.evidence, now: now)
      rescue Hive::RefactorPatrol::LocalMergeCatalog::CatalogError => e
        block_first_owed(entry, reason: e.reason, evidence: e.evidence, now: now)
      end

      def seed_dry_batch(entry, store, snapshot, now:)
        return @dry_batches[entry.fetch("name")] = { head: snapshot.head_sha, merges: [] } unless store.initialized?

        doc = store.state
        catalog = @merge_catalog_factory.call(entry).discover(
          checkpoint_sha: doc.fetch("checkpoint_sha"), head_sha: snapshot.head_sha
        )
        merges = catalog.merges.map do |record|
          record.merge(
            "identity" => store.identity_for(record.fetch("pr_number"), record.fetch("merge_sha"))
          )
        end
        @dry_batches[entry.fetch("name")] = { head: snapshot.head_sha, merges: merges, now: now }
      end

      def prepare_architecture_dispatch(entry, cfg, now:)
        project = entry.fetch("name")
        retained = false
        store = @architecture_store_factory.call(entry)
        guard = @checkout_guard_factory.call(entry, cfg)
        snapshot = guard.acquire!
        capability = probe_capability(entry, cfg, snapshot)
        unless capability.ok?
          block_first_owed(entry, reason: capability.reason, evidence: capability.evidence, now: now)
          return nil
        end

        record = next_architecture_record(project, store, now: now)
        return nil unless record

        expected_head = @dry_run ? @dry_batches.dig(project, :head) : store.state.fetch("active_batch_head")
        if expected_head && snapshot.head_sha != expected_head
          block_record(store, record, reason: "checkout_moved",
                                      evidence: { "batch_head" => expected_head, "head" => snapshot.head_sha }, now: now)
          return nil
        end

        scope = @scope_factory.call(entry, cfg).select(
          changed_paths: record.fetch("changed_paths"), base_sha: record.fetch("base_sha")
        )
        unless scope&.runnable?
          block_record(store, record, reason: scope&.reason || "scope_unusable",
                                      evidence: scope&.evidence || {}, now: now)
          return nil
        end

        unless @dry_run
          store.reserve!(record.fetch("identity"),
                         fingerprint_snapshot: @fingerprint_loader.call(entry.fetch("path")), now: now)
        end
        slug = architecture_slug(record)
        token = architecture_token(entry, snapshot, record, scope, now: now)
        @architecture_pending[project] = {
          slug: slug, store: store, guard: guard, snapshot: snapshot, token: token,
          identity: record.fetch("identity"), dry_run: @dry_run
        }
        retained = true
        {
          project: project,
          slug: slug,
          stage: ARCHITECTURE_STAGE,
          command: Shellwords.join(
            [ capability.executable, "refactor-patrol", project, "--json", *scope.arguments ]
          ),
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry["hive_state_path"],
          patrol_product: :architecture
        }
      rescue Hive::RefactorPatrol::CheckoutGuard::Blocked => e
        block_first_owed(entry, reason: e.reason, evidence: e.evidence, now: now)
        nil
      ensure
        snapshot&.release unless retained
      end

      def next_architecture_record(project, store, now:)
        if @dry_run
          batch = @dry_batches[project]
          batch && batch.fetch(:merges).shift
        else
          store.recover_interrupted!(now: now)
          store.owed_merges.first
        end
      end

      def with_checkout(entry, cfg)
        guard = @checkout_guard_factory.call(entry, cfg)
        snapshot = guard.acquire!
        capability = probe_capability(entry, cfg, snapshot)
        unless capability.ok?
          record_event(:blocked, project: entry.fetch("name"), reason: capability.reason,
                                 evidence: capability.evidence)
          return
        end
        yield guard, snapshot, capability
      ensure
        snapshot&.release
      end

      def probe_capability(entry, cfg, snapshot)
        @capability_probe_factory.call(entry, cfg).call(snapshot.root_realpath)
      end

      def block_first_owed(entry, reason:, evidence:, now:)
        store = @architecture_store_factory.call(entry)
        if store.initialized? && !@dry_run
          record = store.owed_merges.first
          store.record_skip!(record.fetch("identity"), reason: reason, evidence: evidence, now: now) if record
        end
        record_event(:blocked, project: entry.fetch("name"), reason: reason, evidence: evidence)
      rescue Hive::Error, SystemCallError
        record_event(:blocked, project: entry.fetch("name"), reason: reason, evidence: evidence)
      end

      def block_record(store, record, reason:, evidence:, now:)
        store.record_skip!(record.fetch("identity"), reason: reason, evidence: evidence, now: now) unless @dry_run
        record_event(:blocked, project: store.project, reason: reason,
                               evidence: evidence, identity: record.fetch("identity"))
      end

      def complete_architecture(project:, slug:, exit_code:, envelope:, now:)
        pending = @architecture_pending[project]
        return unless pending && (slug.nil? || pending.fetch(:slug) == slug)

        if pending.fetch(:dry_run)
          record_event(:architecture_dry_run_completed, project: project, reason: "dry_run")
        elsif exit_code.to_i != 0
          pending.fetch(:store).record_failure!(pending.fetch(:identity), reason: "child_exit_nonzero",
                                                                          evidence: { "exit_code" => exit_code }, now: now)
          record_event(:failed, project: project, reason: "child_exit_nonzero",
                                evidence: { "exit_code" => exit_code }, identity: pending.fetch(:identity))
        elsif !valid_architecture_envelope?(pending, envelope)
          pending.fetch(:store).record_failure!(pending.fetch(:identity), reason: "invalid_envelope",
                                                                          evidence: {}, now: now)
          record_event(:failed, project: project, reason: "invalid_envelope",
                                evidence: {}, identity: pending.fetch(:identity))
        elsif @architecture_completion
          @architecture_completion.call(
            token: pending.fetch(:token), envelope: envelope, state_store: pending.fetch(:store),
            guard: pending.fetch(:guard), snapshot: pending.fetch(:snapshot), now: now
          )
          record_event(:architecture_completed, project: project, reason: "reported",
                                                identity: pending.fetch(:identity))
        else
          pending.fetch(:store).record_failure!(pending.fetch(:identity), reason: "reporter_unavailable", now: now)
          record_event(:failed, project: project, reason: "reporter_unavailable",
                                identity: pending.fetch(:identity))
        end
      rescue Hive::Error, SystemCallError => e
        pending&.fetch(:store)&.record_failure!(pending.fetch(:identity), reason: "completion_failed",
                                                                         evidence: { "error" => e.message }, now: now)
        record_event(:failed, project: project, reason: "completion_failed", evidence: { "error" => e.message })
      ensure
        pending&.fetch(:snapshot)&.release
        @architecture_pending.delete(project)
      end

      def cancel_architecture(project, slug:, reason:, now:)
        pending = @architecture_pending[project]
        return unless pending && (slug.nil? || pending.fetch(:slug) == slug)

        unless pending.fetch(:dry_run)
          pending.fetch(:store).cancel_reservation!(pending.fetch(:identity), reason: reason, now: now)
        end
      ensure
        pending&.fetch(:snapshot)&.release
        @architecture_pending.delete(project)
      end

      def valid_architecture_envelope?(pending, envelope)
        envelope.is_a?(Hash) && envelope["schema"] == "hive-refactor-patrol" &&
          envelope["ok"] == true && envelope["project"] == pending.dig(:token, "project") &&
          File.expand_path(envelope["project_root"].to_s) == pending.dig(:token, "analysis_root")
      end

      def architecture_slug(record)
        "#{ARCHITECTURE_SLUG_PREFIX}-#{record.fetch('pr_number')}-#{record.fetch('merge_sha')[0, 12]}"
      end

      def architecture_token(entry, snapshot, record, scope, now:)
        {
          "project" => entry.fetch("name"),
          "project_root" => entry.fetch("path"),
          "analysis_root" => snapshot.root_realpath,
          "branch" => snapshot.branch,
          "pinned_head" => snapshot.head_sha,
          "identity" => record.fetch("identity"),
          "pr_number" => record.fetch("pr_number"),
          "merge_sha" => record.fetch("merge_sha"),
          "base_sha" => record.fetch("base_sha"),
          "changed_paths" => record.fetch("changed_paths"),
          "scope" => scope.to_h,
          "started_at" => now.utc.iso8601
        }
      end

      def soft_capability_ancestor(entry, snapshot)
        @git.ancestor?(entry.fetch("path"), CAPABILITY_MERGE_SHA, snapshot.head_sha)
      rescue Hive::GitError
        nil
      end

      def record_event(type, project:, reason:, evidence: {}, identity: nil)
        @last_events << { type: type, project: project, reason: reason,
                          evidence: evidence, identity: identity }.compact
      end

      def dispatch_for(entry)
        project = entry.fetch("name")
        {
          project: project,
          slug: PATROL_SLUG,
          stage: PATROL_STAGE,
          command: "hive patrol #{Shellwords.escape(project)} --json",
          state_file_mtime: nil,
          state_file_path: nil,
          hive_state_path: entry["hive_state_path"]
        }
      end
    end
  end
end
