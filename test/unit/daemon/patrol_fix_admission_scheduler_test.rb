require "test_helper"
require "tmpdir"
require "hive/commands/init"
require "hive/daemon/patrol_fix_admission_scheduler"
require "hive/patrol/finding"
require "hive/patrol/fix_admission_outbox"
require "hive/patrol_fix/admission_store"
require "hive/patrol_fix/cutover_gate"
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

  def test_drains_accepted_source_while_discovery_is_exhausted_without_patrol_budget
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        gate = Hive::PatrolFix::CutoverGate.new(enabled: true, epoch: "epoch-test")
        source = Hive::Patrol::FixAdmissionOutbox.new(
          root: File.join(hive_state, "patrol", "patrol-fix-outbox"), gate: gate
        )
        source.publish_finding!(finding, accepted_at: NOW)
        admission = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(hive_state, "patrol-fix", "admissions")
        )
        capacity_checks = 0
        provider_calls = 0
        services = []
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ], admission_store: admission,
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
          task_materializer_factory: lambda do |store:, source_acknowledger:, **_args|
            Hive::PatrolFix::TaskMaterializer.new(
              project_root: project_root, hive_state: hive_state, store: store,
              workflow_info: {
                descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
                pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
              },
              source_acknowledger: source_acknowledger, clock: -> { NOW }
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
        assert_empty source.pending
        assert_equal 1, Dir.glob(File.join(hive_state, "stages", "1-inbox", "*", "meta.yml")).length
      end
    end
  end

  def test_insufficient_evidence_parks_the_handoff_without_ack_or_hot_retry
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        source = Hive::Patrol::FixAdmissionOutbox.new(
          root: File.join(hive_state, "patrol", "patrol-fix-outbox"),
          gate: Hive::PatrolFix::CutoverGate.new(enabled: true, epoch: "epoch-test")
        )
        entry = source.publish_finding!(finding, accepted_at: NOW)
        admission = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(hive_state, "patrol-fix", "admissions")
        )
        services = []
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ], admission_store: admission,
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
        scheduler.complete(
          dispatch_token: dispatch.dispatch_token, exit_code: 0, envelope: { "ok" => true },
          now: NOW + 1
        )
        assert_equal [ :blocked ], scheduler.tick(now: NOW + 2).map(&:status)
        assert_empty source.pending
        refute source.acknowledged?(entry.fetch("occurrence_id"))
        assert_equal "blocked", admission.visible_blocked.first.fetch("status")
        assert_empty scheduler.tick(now: NOW + 60)
      end
    end
  end

  def test_provider_failure_defers_the_source_handoff_until_retry_eligibility
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        source = Hive::Patrol::FixAdmissionOutbox.new(
          root: File.join(hive_state, "patrol", "patrol-fix-outbox"),
          gate: Hive::PatrolFix::CutoverGate.new(enabled: true, epoch: "epoch-test")
        )
        entry = source.publish_finding!(finding, accepted_at: NOW)
        admission = Hive::PatrolFix::AdmissionStore.new(
          root: File.join(hive_state, "patrol-fix", "admissions")
        )
        launches = 0
        services = []
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ], admission_store: admission,
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
        assert_empty source.pending(now: NOW + 299)
        assert_empty scheduler.tick(now: NOW + 299)
        assert_equal [ entry.fetch("occurrence_id") ],
                     source.pending(now: NOW + 301).map { |record| record.fetch("occurrence_id") }
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
        sources: [ source ], admission_store: admission,
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
      assert_empty source.pending(now: retry_at - 1)
      assert_equal [ entry.fetch("occurrence_id") ],
                   source.pending(now: retry_at).map { |record| record.fetch("occurrence_id") }
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
      assert_empty source.pending(now: NOW + 299)
      recovered = scheduler.tick(now: NOW + 302)
      assert_equal [ :acknowledged ], recovered.map(&:status), recovered.map(&:reason).inspect
      assert_equal 1, semantic_launches
      assert_equal 2, materialization_attempts
      assert_empty source.pending(now: NOW + 302)
    end
  end

  def test_source_acknowledgement_reconciles_when_admission_ack_write_fails_once
    with_initialized_scheduler_project do |project_root, hive_state, source, entry|
      admission = OneShotAcknowledgementFailureStore.new(
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
      assert source.acknowledged?(occurrence_id)
      assert_empty source.pending(now: NOW + 299)

      recovered = scheduler.tick(now: NOW + 302)
      assert_equal [ :acknowledged ], recovered.map(&:status), recovered.map(&:reason).inspect
      assert_equal "acknowledged", admission.fetch(occurrence_id).fetch("status")
      assert_empty source.pending(now: NOW + 302)
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
      waiting = restarted.tick(now: NOW + 60).fetch(0)
      assert_equal :decision_in_flight, waiting.status
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

  private

  def with_initialized_scheduler_project
    with_tmp_global_config do
      with_tmp_git_repo do |project_root|
        capture_io { Hive::Commands::Init.new(project_root, agent_skill_preflight: false).call }
        hive_state = File.join(project_root, ".hive-state")
        source = Hive::Patrol::FixAdmissionOutbox.new(
          root: File.join(hive_state, "patrol", "patrol-fix-outbox"),
          gate: Hive::PatrolFix::CutoverGate.new(enabled: true, epoch: "epoch-test")
        )
        entry = source.publish_finding!(finding, accepted_at: NOW)
        yield project_root, hive_state, source, entry
      end
    end
  end

  def scheduler_for(project_root, source, admission, decision_provider:, materializer_factory:)
    services = []
    scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
      sources: [ source ], admission_store: admission,
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

  def real_materializer(project_root, hive_state, store:, source_acknowledger:, **_args)
    Hive::PatrolFix::TaskMaterializer.new(
      project_root: project_root, hive_state: hive_state, store: store,
      workflow_info: {
        descriptor: Hive::Workflows::Registry.fetch(:"patrol-fix"),
        pin: true, managed: nil, managed_cfg: {}, authored_digest: nil
      },
      source_acknowledger: source_acknowledger, clock: -> { NOW }
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
