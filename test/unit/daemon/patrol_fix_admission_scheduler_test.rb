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
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ], admission_store: admission,
          capacity_available: lambda do |**_args|
            capacity_checks += 1
            true
          end,
          semantic_admission_factory: lambda do |store:, **_args|
            Hive::PatrolFix::SemanticAdmission.new(
              store: store, candidate_provider: ->(_snapshot) { [] },
              current_head: -> { "2" * 40 },
              decision_provider: lambda do |_input|
                {
                  "decision" => "distinct", "candidate_identity" => nil,
                  "rationale" => "No shared root", "evidence" => [ "No candidate" ],
                  "model_receipt" => "fake-provider:distinct"
                }
              end,
              clock: -> { NOW }
            )
          end,
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

        events = scheduler.tick(now: NOW)

        assert_equal 1, capacity_checks
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
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ], admission_store: admission,
          semantic_admission_factory: lambda do |store:, **_args|
            Hive::PatrolFix::SemanticAdmission.new(
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
          end,
          task_materializer_factory: ->(**) { flunk "blocked admission must not materialize" },
          clock: -> { NOW }
        )

        assert_equal [ :blocked ], scheduler.tick(now: NOW).map(&:status)
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
        scheduler = Hive::Daemon::PatrolFixAdmissionScheduler.new(
          sources: [ source ], admission_store: admission,
          semantic_admission_factory: lambda do |store:, **_args|
            Hive::PatrolFix::SemanticAdmission.new(
              store: store, candidate_provider: ->(_snapshot) { [] },
              current_head: -> { "2" * 40 },
              decision_provider: lambda do |_input|
                launches += 1
                raise "provider limited"
              end,
              clock: -> { NOW }
            )
          end,
          task_materializer_factory: ->(**) { flunk "retrying admission must not materialize" },
          retry_policy: ->(_record, _error, now) { now + 300 },
          clock: -> { NOW }
        )

        assert_equal [ :retry_wait ], scheduler.tick(now: NOW).map(&:status)
        assert_equal 1, launches
        assert_empty source.pending(now: NOW + 299)
        assert_empty scheduler.tick(now: NOW + 299)
        assert_equal [ entry.fetch("occurrence_id") ],
                     source.pending(now: NOW + 300).map { |record| record.fetch("occurrence_id") }
      end
    end
  end

  def test_materialization_failure_retries_without_repeating_semantic_admission
    with_initialized_scheduler_project do |project_root, hive_state, source, entry|
      admission = Hive::PatrolFix::AdmissionStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      semantic_launches = 0
      materialization_attempts = 0
      scheduler = scheduler_for(
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

      assert_equal [ :retry_wait ], scheduler.tick(now: NOW).map(&:status)
      assert_empty source.pending(now: NOW + 299)
      recovered = scheduler.tick(now: NOW + 300)
      assert_equal [ :acknowledged ], recovered.map(&:status), recovered.map(&:reason).inspect
      assert_equal 1, semantic_launches
      assert_equal 2, materialization_attempts
      assert_empty source.pending(now: NOW + 300)
    end
  end

  def test_source_acknowledgement_reconciles_when_admission_ack_write_fails_once
    with_initialized_scheduler_project do |project_root, hive_state, source, entry|
      admission = OneShotAcknowledgementFailureStore.new(
        root: File.join(hive_state, "patrol-fix", "admissions")
      )
      scheduler = scheduler_for(
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

      assert_equal [ :retry_wait ], scheduler.tick(now: NOW).map(&:status)
      occurrence_id = entry.fetch("occurrence_id")
      assert source.acknowledged?(occurrence_id)
      assert_empty source.pending(now: NOW + 299)

      recovered = scheduler.tick(now: NOW + 300)
      assert_equal [ :acknowledged ], recovered.map(&:status), recovered.map(&:reason).inspect
      assert_equal "acknowledged", admission.fetch(occurrence_id).fetch("status")
      assert_empty source.pending(now: NOW + 300)
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
    Hive::Daemon::PatrolFixAdmissionScheduler.new(
      sources: [ source ], admission_store: admission,
      semantic_admission_factory: lambda do |store:, **_args|
        Hive::PatrolFix::SemanticAdmission.new(
          store: store, candidate_provider: ->(_snapshot) { [] },
          current_head: -> { "2" * 40 }, decision_provider: decision_provider,
          clock: -> { NOW }
        )
      end,
      task_materializer_factory: materializer_factory,
      retry_policy: ->(_record, _error, now) { now + 300 },
      clock: -> { NOW }
    )
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
