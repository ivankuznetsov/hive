require "test_helper"
require "tmpdir"
require "hive/commands/init"
require "hive/daemon/patrol_fix_admission_scheduler"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_adapter"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/semantic_admission"
require "hive/patrol_fix/task_materializer"
require "hive/workflows/registry"

class PatrolFixAdmissionSchedulerTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 8, 20, 12)
  QuotaError = Class.new(StandardError) do
    attr_reader :retry_at
    def initialize(retry_at)
      @retry_at = retry_at
      super("provider quota exhausted")
    end
  end

  BrokenStore = Class.new do
    def pending(**) = raise(Hive::ConfigError, "corrupt source record")
  end

  HealthyEmptyStore = Struct.new(:pending_calls) do
    def pending(**)
      self.pending_calls += 1
      []
    end
  end
  ProjectSource = Struct.new(:project, :store)

  def test_one_unavailable_source_does_not_stop_other_projects_from_draining
    healthy_store = HealthyEmptyStore.new(0)
    scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
      sources: [
        ProjectSource.new("ordinary-project", BrokenStore.new),
        ProjectSource.new("architecture-project", healthy_store)
      ],
      clock: -> { NOW }
    )

    events = scheduler.tick(now: NOW)

    assert_equal 1, healthy_store.pending_calls
    assert_equal [ :failed ], events.map(&:status)
    assert_equal "ordinary-project", events.first.source
    assert_match(/source_unavailable: Hive::ConfigError/, events.first.reason)
  end

  def test_drains_accepted_source_while_discovery_is_exhausted_without_patrol_budget
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        source = Hive::Patrol::FixAdmissionAdapter.for_project(
          project_root: project_root, hive_state_path: hive_state
        )
        source.publish_finding!(finding, accepted_at: NOW)
        admission = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(hive_state, "patrol-fix", "admissions")
        )
        capacity_checks = 0
        provider_calls = 0
        services = []
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ],
          capacity_available: lambda do |**_args|
            capacity_checks += 1
            true
          end,
          semantic_admission_factory: lambda do |store:, **_args|
            semantic = Hive::PatrolFix::SemanticAdmission.new(
              store: store, candidate_provider: ->(_snapshot) { [] },
              current_head: -> { "2" * 40 },
              decision_provider: lambda do |_input|
                provider_calls += 1
                {
                  "decision" => "distinct", "candidate_identity" => nil,
                  "rationale" => "No shared root", "evidence" => [ "No candidate" ],
                  "model_receipt" => "fake-provider:distinct"
                }
              end,
              clock: -> { NOW }
            )
            services << semantic
            semantic
          end,
          semantic_command_factory: ->(_token) { "hive __patrol-fix-semantic-decision test" },
          task_materializer_factory: lambda do |store:, **_args|
            Hive::PatrolFix::TaskMaterializer.new(
              project_root: project_root, hive_state: hive_state, store: store,
              workflow_info: {
                descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
                pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
              },
              clock: -> { NOW }
            )
          end,
          clock: -> { NOW }
        )

        dispatch = scheduler.tick(now: NOW).fetch(0)
        assert_equal :decision_dispatch, dispatch.status
        assert_equal 0, provider_calls
        services.fetch(0).run_reserved(
          occurrence_id: dispatch.occurrence_id,
          reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
        )
        assert_equal 1, provider_calls
        scheduler.complete(
          dispatch_token: dispatch.dispatch_token, exit_code: 0, envelope: { "ok" => true },
          now: NOW + 1
        )
        events = scheduler.tick(now: NOW + 2)

        assert_equal 2, capacity_checks
        assert_equal [ :acknowledged ], events.map(&:status)
        assert_empty admission.pending
        assert_equal 1, Dir.glob(File.join(hive_state, "stages", "1-inbox", "*", "meta.yml")).length
      end
    end
  end

  def test_insufficient_evidence_blocks_the_admission_without_ack_or_hot_retry
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        source = Hive::Patrol::FixAdmissionAdapter.for_project(
          project_root: project_root, hive_state_path: hive_state
        )
        entry = source.publish_finding!(finding, accepted_at: NOW)
        admission = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(hive_state, "patrol-fix", "admissions")
        )
        services = []
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ],
          semantic_admission_factory: lambda do |store:, **_args|
            semantic = Hive::PatrolFix::SemanticAdmission.new(
              store: store, candidate_provider: ->(_snapshot) { [] },
              current_head: -> { "2" * 40 },
              decision_provider: lambda do |_input|
                {
                  "decision" => "insufficient_evidence", "candidate_identity" => nil,
                  "rationale" => "Cannot distinguish the root",
                  "evidence" => [ "The observed overlap is ambiguous" ],
                  "model_receipt" => "fake-provider:blocked"
                }
              end,
              clock: -> { NOW }
            )
            services << semantic
            semantic
          end,
          semantic_command_factory: ->(_token) { "hive __patrol-fix-semantic-decision test" },
          task_materializer_factory: ->(**) { flunk "blocked admission must not materialize" },
          clock: -> { NOW }
        )

        dispatch = scheduler.tick(now: NOW).fetch(0)
        assert_equal :decision_dispatch, dispatch.status
        services.fetch(0).run_reserved(
          occurrence_id: dispatch.occurrence_id,
          reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
        )
        completion = scheduler.complete(
          dispatch_token: dispatch.dispatch_token, exit_code: 0, envelope: { "ok" => true },
          now: NOW + 1
        )
        assert_equal :blocked, completion.status
        assert_empty admission.pending
        assert_nil admission.fetch(entry.fetch("occurrence_id"))["acknowledgement"]
        assert_equal "blocked", admission.visible_blocked.first.fetch("status")
        assert_empty scheduler.tick(now: NOW + 60)
      end
    end
  end

  def test_provider_failure_defers_the_admission_until_retry_eligibility
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        source = Hive::Patrol::FixAdmissionAdapter.for_project(
          project_root: project_root, hive_state_path: hive_state
        )
        entry = source.publish_finding!(finding, accepted_at: NOW)
        admission = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(hive_state, "patrol-fix", "admissions")
        )
        launches = 0
        services = []
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ],
          semantic_admission_factory: lambda do |store:, **_args|
            semantic = Hive::PatrolFix::SemanticAdmission.new(
              store: store, candidate_provider: ->(_snapshot) { [] },
              current_head: -> { "2" * 40 },
              decision_provider: lambda do |_input|
                launches += 1
                raise "provider limited"
              end,
              clock: -> { NOW }
            )
            services << semantic
            semantic
          end,
          semantic_command_factory: ->(_token) { "hive __patrol-fix-semantic-decision test" },
          task_materializer_factory: ->(**) { flunk "retrying admission must not materialize" },
          retry_policy: ->(_record, _error, now) { now + 300 },
          clock: -> { NOW }
        )

        dispatch = scheduler.tick(now: NOW).fetch(0)
        error = assert_raises(StandardError) do
          services.fetch(0).run_reserved(
            occurrence_id: dispatch.occurrence_id,
            reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
          )
        end
        completion = scheduler.complete(
          dispatch_token: dispatch.dispatch_token, exit_code: 1,
          envelope: { "error" => error.message, "error_class" => error.class.name }, now: NOW + 1
        )
        assert_equal :retry_wait, completion.status
        assert_equal 1, launches
        assert_empty admission.pending(now: NOW + 299)
        assert_empty scheduler.tick(now: NOW + 299)
        assert_equal [ entry.fetch("occurrence_id") ],
                     admission.pending(now: NOW + 301).map { |record| record.fetch("occurrence_id") }
      end
    end
  end

  def test_provider_retry_at_wins_over_short_default_backoff
    with_initialized_scheduler_project do |_project_root, hive_state, source, entry|
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      retry_at = NOW + 7_200
      services = []
      scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
        sources: [ source ],
        semantic_admission_factory: lambda do |store:, **_args|
          semantic = Hive::PatrolFix::SemanticAdmission.new(
            store: store, candidate_provider: ->(_snapshot) { [] },
            current_head: -> { "2" * 40 },
            decision_provider: ->(_input) { raise QuotaError, retry_at.iso8601 },
            clock: -> { NOW }
          )
          services << semantic
          semantic
        end,
        semantic_command_factory: ->(_token) { "hive __patrol-fix-semantic-decision test" },
        task_materializer_factory: ->(**) { flunk "quota failure must not materialize" },
        clock: -> { NOW }
      )

      dispatch = scheduler.tick(now: NOW).fetch(0)
      error = assert_raises(QuotaError) do
        services.fetch(0).run_reserved(
          occurrence_id: dispatch.occurrence_id,
          reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
        )
      end
      event = scheduler.complete(
        dispatch_token: dispatch.dispatch_token, exit_code: 1,
        envelope: {
          "error" => error.message, "error_class" => error.class.name,
          "retry_at" => error.retry_at
        }, now: NOW + 1
      )

      assert_equal :retry_wait, event.status
      assert_equal retry_at.iso8601, event.retry_at
      assert_empty admission.pending(now: retry_at - 1)
      assert_equal [ entry.fetch("occurrence_id") ],
                   admission.pending(now: retry_at).map { |record| record.fetch("occurrence_id") }
    end
  end

  def test_materialization_failure_retries_without_repeating_semantic_admission
    with_initialized_scheduler_project do |project_root, hive_state, source, entry|
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      semantic_launches = 0
      materialization_attempts = 0
      scheduler, services = scheduler_for(
        project_root, source, admission,
        decision_provider: lambda do |_input|
          semantic_launches += 1
          {
            "decision" => "distinct", "candidate_identity" => nil,
            "rationale" => "No shared root", "evidence" => [ "No candidate" ],
            "model_receipt" => "fake-provider:distinct"
          }
        end,
        materializer_factory: lambda do |**options|
          materialization_attempts += 1
          if materialization_attempts == 1
            Object.new.tap do |value|
              value.define_singleton_method(:call) { |_occurrence_id| raise "task store unavailable" }
            end
          else
            real_materializer(project_root, hive_state, **options)
          end
        end
      )

      dispatch = scheduler.tick(now: NOW).fetch(0)
      services.fetch(0).run_reserved(
        occurrence_id: dispatch.occurrence_id,
        reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
      )
      scheduler.complete(
        dispatch_token: dispatch.dispatch_token, exit_code: 0, envelope: { "ok" => true },
        now: NOW + 1
      )
      assert_equal [ :retry_wait ], scheduler.tick(now: NOW + 2).map(&:status)
      assert_empty admission.pending(now: NOW + 299)
      recovered = scheduler.tick(now: NOW + 302)
      assert_equal [ :acknowledged ], recovered.map(&:status), recovered.map(&:reason).inspect
      assert_equal 1, semantic_launches
      assert_equal 2, materialization_attempts
      assert_empty admission.pending(now: NOW + 302)
    end
  end

  def test_stale_materialization_reopens_admission_without_retry
    with_initialized_scheduler_project do |project_root, hive_state, source, entry|
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      scheduler, services = scheduler_for(
        project_root, source, admission,
        decision_provider: lambda do |_input|
          {
            "decision" => "distinct", "candidate_identity" => nil,
            "rationale" => "No shared root", "evidence" => [ "No candidate" ],
            "model_receipt" => "fake-provider:distinct"
          }
        end,
        materializer_factory: lambda do |**|
          Object.new.tap do |materializer|
            materializer.define_singleton_method(:call) do |occurrence_id|
              admission.reset_decided_stale!(occurrence_id, now: NOW + 2)
              raise Hive::PatrolFix::AdmissionStore::StaleDecision, "candidate set changed"
            end
          end
        end
      )

      dispatch = scheduler.tick(now: NOW).fetch(0)
      services.fetch(0).run_reserved(
        occurrence_id: dispatch.occurrence_id,
        reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
      )
      scheduler.complete(
        dispatch_token: dispatch.dispatch_token, exit_code: 0, envelope: { "ok" => true },
        now: NOW + 1
      )

      event = scheduler.tick(now: NOW + 2).fetch(0)
      record = admission.fetch(entry.fetch("occurrence_id"))

      assert_equal :stale, event.status
      assert_equal "candidate_digest_changed", event.reason
      assert_equal "pending", record.fetch("status")
      assert_nil record["retry"]
      assert_equal [ :decision_dispatch ], scheduler.tick(now: NOW + 3).map(&:status)
    end
  end

  def test_durable_task_reconciles_when_admission_ack_write_fails_once
    with_initialized_scheduler_project do |project_root, hive_state, source, entry|
      admission = OneShotAcknowledgementFailureStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      source.define_singleton_method(:store) { admission }
      scheduler, services = scheduler_for(
        project_root, source, admission,
        decision_provider: lambda do |_input|
          {
            "decision" => "distinct", "candidate_identity" => nil,
            "rationale" => "No shared root", "evidence" => [ "No candidate" ],
            "model_receipt" => "fake-provider:distinct"
          }
        end,
        materializer_factory: lambda do |**options|
          real_materializer(project_root, hive_state, **options)
        end
      )

      dispatch = scheduler.tick(now: NOW).fetch(0)
      services.fetch(0).run_reserved(
        occurrence_id: dispatch.occurrence_id,
        reservation_id: dispatch.dispatch_token.fetch(:reservation_id)
      )
      scheduler.complete(
        dispatch_token: dispatch.dispatch_token, exit_code: 0, envelope: { "ok" => true },
        now: NOW + 1
      )
      assert_equal [ :retry_wait ], scheduler.tick(now: NOW + 2).map(&:status)
      occurrence_id = entry.fetch("occurrence_id")
      assert_equal "retry_wait", admission.fetch(occurrence_id).fetch("status")
      assert admission.fetch(occurrence_id).fetch("task")
      assert_empty admission.pending(now: NOW + 299)

      recovered = scheduler.tick(now: NOW + 302)
      assert_equal [ :acknowledged ], recovered.map(&:status), recovered.map(&:reason).inspect
      assert_equal "acknowledged", admission.fetch(occurrence_id).fetch("status")
      assert_empty admission.pending(now: NOW + 302)
    end
  end

  def test_restart_waits_for_the_live_lease_then_replaces_it_and_fences_the_old_child
    with_initialized_scheduler_project do |project_root, hive_state, source, _entry|
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      provider_calls = 0
      decision = lambda do |_input|
        provider_calls += 1
        {
          "decision" => "distinct", "candidate_identity" => nil,
          "rationale" => "No shared root", "evidence" => [ "No candidate" ],
          "model_receipt" => "fake-provider:distinct"
        }
      end
      first, old_services = scheduler_for(
        project_root, source, admission, decision_provider: decision,
        materializer_factory: ->(**) { flunk "decision is not materialized in this proof" }
      )
      old_dispatch = first.tick(now: NOW).fetch(0)

      restarted, new_services = scheduler_for(
        project_root, source, admission, decision_provider: decision,
        materializer_factory: ->(**) { flunk "decision is not materialized in this proof" }
      )
      assert_empty restarted.tick(now: NOW + 60)
      assert_empty new_services
      assert_equal 0, provider_calls

      timeout = first.complete(
        dispatch_token: old_dispatch.dispatch_token, exit_code: 1,
        envelope: { "error" => "timed out" }, now: NOW + 7_201
      )
      assert_equal :stale, timeout.status
      assert_equal "reservation_expired", timeout.reason

      replacement = restarted.tick(now: NOW + 7_201).fetch(0)
      assert_equal :decision_dispatch, replacement.status
      refute_equal old_dispatch.dispatch_token.fetch(:reservation_id),
                   replacement.dispatch_token.fetch(:reservation_id)
      assert_raises(Hive::PatrolFix::AdmissionStore::StaleDecision) do
        old_services.fetch(0).run_reserved(
          occurrence_id: old_dispatch.occurrence_id,
          reservation_id: old_dispatch.dispatch_token.fetch(:reservation_id),
          now: NOW + 7_202
        )
      end
      new_services.fetch(0).run_reserved(
        occurrence_id: replacement.occurrence_id,
        reservation_id: replacement.dispatch_token.fetch(:reservation_id),
        now: NOW + 7_202
      )
      assert_equal 1, provider_calls
    end
  end

  def test_rejects_invalid_batch_limits
    [ 0, 65 ].each do |limit|
      assert_raises(ArgumentError) do
        Hive::Daemon::PatrolFixAdmissionScheduler.new(limit: limit)
      end
    end
  end

  def test_capacity_denial_leaves_pending_admission_untouched
    with_initialized_scheduler_project do |_project_root, hive_state, source, entry|
      scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
        sources: -> { [ source ] }, capacity_available: ->(**) { false }, clock: -> { NOW }
      )

      event = scheduler.tick.fetch(0)

      assert_equal :capacity_blocked, event.status
      assert_equal "workflow_capacity", event.reason
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      assert_equal "pending", admission.fetch(entry.fetch("occurrence_id")).fetch("status")
    end
  end

  def test_missing_semantic_factory_enters_bounded_retry
    with_initialized_scheduler_project do |_project_root, hive_state, source, entry|
      scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
        sources: [ source ], clock: -> { NOW }
      )

      event = scheduler.tick.fetch(0)

      assert_equal :retry_wait, event.status
      assert_equal (NOW + 60).iso8601, event.retry_at
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      assert_equal "retry_wait", admission.fetch(entry.fetch("occurrence_id")).fetch("status")
    end
  end

  def test_semantic_staleness_is_reported_without_retry
    with_initialized_scheduler_project do |_project_root, _hive_state, source, _entry|
      semantic = Object.new
      semantic.define_singleton_method(:prepare) do |**|
        raise Hive::PatrolFix::AdmissionStore::StaleDecision, "changed"
      end
      scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
        sources: [ source ], semantic_admission_factory: ->(**) { semantic }, clock: -> { NOW }
      )

      event = scheduler.tick.fetch(0)

      assert_equal :stale, event.status
      assert_equal "candidate_digest_changed", event.reason
    end
  end

  def test_cancel_releases_unlaunched_reservation_and_fences_replay
    with_initialized_scheduler_project do |project_root, hive_state, source, _entry|
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      scheduler, = scheduler_for(
        project_root, source, admission,
        decision_provider: ->(_input) { flunk "cancelled decision must not run" },
        materializer_factory: ->(**) { flunk "cancelled decision must not materialize" }
      )
      dispatch = scheduler.tick.fetch(0)

      assert_nil scheduler.cancel(dispatch_token: { kind: :other })
      cancelled = scheduler.cancel(dispatch_token: dispatch.dispatch_token, now: NOW + 1)
      stale = scheduler.cancel(dispatch_token: dispatch.dispatch_token, now: NOW + 2)

      assert_equal :cancelled, cancelled.status
      assert_equal :stale, stale.status
      assert_equal "reservation_changed", stale.reason
    end
  end

  def test_completion_handles_irrelevant_unknown_and_already_decided_tokens
    with_initialized_scheduler_project do |project_root, hive_state, source, _entry|
      source.define_singleton_method(:project) { project_root }
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      scheduler, services = scheduler_for(
        project_root, source, admission,
        decision_provider: lambda do |_input|
          {
            "decision" => "distinct", "candidate_identity" => nil,
            "rationale" => "No shared root", "evidence" => [ "No candidate" ],
            "model_receipt" => "fake-provider:distinct"
          }
        end,
        materializer_factory: ->(**) { flunk "completion does not materialize" }
      )
      dispatch = scheduler.tick.fetch(0)

      assert_nil scheduler.complete(
        dispatch_token: { kind: :other }, exit_code: 0, envelope: {}, now: NOW
      )
      unknown = dispatch.dispatch_token.merge(project: "missing")
      assert_equal :stale, scheduler.complete(
        dispatch_token: unknown, exit_code: 1, envelope: {}, now: NOW
      ).status
      services.fetch(0).run_reserved(
        occurrence_id: dispatch.occurrence_id,
        reservation_id: dispatch.dispatch_token.fetch(:reservation_id), now: NOW + 1
      )

      completed = scheduler.complete(
        dispatch_token: dispatch.dispatch_token, exit_code: 0, envelope: {}, now: NOW + 2
      )
      assert_equal :decision_completed, completed.status
    end
  end

  def test_default_command_requires_project_and_shell_escapes_values
    scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new
    error = assert_raises(Hive::ConfigError) do
      scheduler.send(
        :semantic_command,
        project: "", source: "ordinary_patrol", occurrence_id: "finding",
        reservation_id: "a" * 64
      )
    end
    assert_match(/project is unavailable/, error.message)

    command = scheduler.send(
      :semantic_command,
      project: "demo project", source: "ordinary_patrol", occurrence_id: "finding one",
      reservation_id: "a" * 64
    )
    assert_includes command, "demo\\ project"
    assert_includes command, "finding\\ one"
  end

  def test_malformed_completion_token_returns_bounded_failure
    scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
      sources: [ ProjectSource.new("demo", HealthyEmptyStore.new(0)) ]
    )

    event = scheduler.complete(
      dispatch_token: { kind: :patrol_fix_semantic_admission },
      exit_code: 1, envelope: {}, now: NOW
    )

    assert_equal :failed, event.status
    assert_match(/completion_failure: KeyError/, event.reason)
  end

  def test_default_clock_and_invalid_source_boundaries_fail_closed
    scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(sources: [])
    assert_empty scheduler.tick

    assert_raises(Hive::ConfigError) do
      scheduler.send(:store_for, Object.new)
    end

    source = ProjectSource.new("demo", Struct.new(:record) {
      def fetch(*) = record
    }.new(nil))
    event = scheduler.send(
      :process, source, { "occurrence_id" => "missing" }, now: NOW
    )
    assert_equal :failed, event.status
    assert_match(/admission occurrence is missing/, event.reason)

    malformed_retry = Struct.new(:retry_at).new("not-a-time")
    assert_nil scheduler.send(:provider_retry_at, malformed_retry)
  end

  private

  def with_initialized_scheduler_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        source = Hive::Patrol::FixAdmissionAdapter.for_project(
          project_root: project_root, hive_state_path: hive_state
        )
        entry = source.publish_finding!(finding, accepted_at: NOW)
        yield project_root, hive_state, source, entry
      end
    end
  end

  def scheduler_for(project_root, source, admission, decision_provider:, materializer_factory:)
    services = []
    scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
      sources: [ source ],
      semantic_admission_factory: lambda do |store:, **_args|
        semantic = Hive::PatrolFix::SemanticAdmission.new(
          store: store, candidate_provider: ->(_snapshot) { [] },
          current_head: -> { "2" * 40 }, decision_provider: decision_provider,
          clock: -> { NOW }
        )
        services << semantic
        semantic
      end,
      semantic_command_factory: ->(_token) { "hive __patrol-fix-semantic-decision test" },
      task_materializer_factory: materializer_factory,
      retry_policy: ->(_record, _error, now) { now + 300 },
      clock: -> { NOW }
    )
    [ scheduler, services ]
  end

  def real_materializer(project_root, hive_state, store:, **_args)
    Hive::PatrolFix::TaskMaterializer.new(
      project_root: project_root, hive_state: hive_state, store: store,
      workflow_info: {
        descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
        pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
      },
      clock: -> { NOW }
    )
  end

  class OneShotAcknowledgementFailureStore < Hive::PatrolFix::AdmissionStore
    def acknowledge!(...)
      unless defined?(@failed_once)
        @failed_once = true
        raise "admission acknowledgement unavailable"
      end
      super
    end
  end

  def finding
    Hive::Patrol::Finding.new(
      id: "finding-1", feature_id: "refresh", category: "bug",
      severity: "high", confidence: "high", title: "Repair refresh",
      description: "Refresh fails", recommendation: "Consolidate recovery",
      scope: "feature", contract: "Refresh remains usable", impact: "Sessions fail",
      root_cause: "Two owners race", reproduction: "Run the refresh spec",
      validation: "Run test/refresh_test.rb", evidence: [ "Reachable failure" ],
      fingerprint: "refresh-root", validation_key: "refresh-v1",
      target_sha: "1" * 40, lifecycle_state: "active",
      lifecycle_reason: "admitted", lifecycle_updated_at: NOW.iso8601
    )
  end
end
