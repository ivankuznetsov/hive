require "test_helper"
require "hive"
require "hive/modules/migration/qualification_checkpoint_evidence"
require "hive/modules/migration/qualification_checkpoint_verifier"
require "hive/modules/migration/qualification_scenario_driver"
require "hive/modules/migration/qualification_scenario_actuals"
require "hive/modules/migration/qualification_scenario_input"

class ModulesMigrationQualificationScenarioDriverTest < Minitest::Test
  include HiveTestHelper

  DRIVER = Hive::Modules::Migration::QualificationScenarioDriver
  CHECKPOINTS =
    Hive::Modules::Migration::QualificationCheckpointEvidence
  CHECKPOINT_VERIFIER =
    Hive::Modules::Migration::QualificationCheckpointVerifier
  ACTUALS =
    Hive::Modules::Migration::QualificationScenarioActuals
  INPUT =
    Hive::Modules::Migration::QualificationScenarioInput
  NOW = Time.utc(2026, 7, 31, 12, 34, 56, 123_456)
  PROJECT = {
    "project_id" => "11111111-1111-4111-8111-111111111111",
    "name" => "qualification-demo",
    "repository" => "github.com/example/qualification-demo"
  }.freeze
  CANDIDATE_SOURCE_ROOT =
    File.expand_path("../../../..", __dir__).freeze

  class RecordingProviderClient
    attr_reader :calls

    def initialize(outputs)
      @outputs = outputs
      @calls = []
    end

    def call(kind:, prompt:, context_refs:, output_ref:)
      @calls << {
        kind: kind,
        prompt: prompt,
        context_refs: context_refs,
        output_ref: output_ref
      }.freeze
      FileUtils.mkdir_p(File.dirname(output_ref))
      File.binwrite(
        output_ref,
        Hive::WorkflowPackage::CanonicalJSON.generate(
          @outputs.fetch(kind)
        )
      )
      true
    end
  end

  def test_drives_one_ordinary_patrol_case_through_production_artifacts
    with_tmp_dir do |sandbox|
      result = run_driver(sandbox)
      row = result.observation

      assert File.directory?(File.join(result.repository_root, ".git"))
      assert_equal(
        run!("git", "-C", result.repository_root, "rev-parse", "HEAD").strip,
        row.fetch("repository_sha")
      )
      assert_match(/\A[0-9a-f]{40}\z/, row.fetch("repository_sha"))
      assert_equal "", run!("git", "-C", result.repository_root, "remote").strip

      ledger = Hive::Modules::EventLedger.new(
        root: File.join(result.hive_state_path, "module-runtime")
      )
      assert_equal row.fetch("event"),
                   ledger.fetch(row.fetch("event_id"))
      capture = Hive::Modules::Migration::PatrolCapture.from_h(
        row.dig("event", "payload", "legacy_mutator_capture")
      )
      assert_equal row.fetch("legacy_capture_id"), capture.capture_id
      assert_equal "completed", capture.outcome_class
      assert_equal "due", capture.selection.rationale
      refute row.key?("decision_class")
      assert_equal 0, capture.outcome.fetch("findings")
      assert_equal "legacy", capture.owner

      journal = Hive::Modules::DecisionJournal.new(
        root: File.join(result.hive_state_path, "module-runtime")
      )
      decisions = journal.all
      primary_decision = row.fetch("decisions").fetch(0)
      assert_includes decisions, primary_decision
      assert decisions.reject { |decision| decision == primary_decision }
        .all? do |decision|
          decision.fetch("outcome") == "skip" &&
            decision["attempt_id"].nil?
        end
      assert_equal "launch", primary_decision.fetch("outcome")
      assert_equal "admitted", primary_decision.fetch("reason")

      attempt_store = Hive::Attempts::Store.new(root: result.attempts_root)
      scan = attempt_store.scan
      assert_empty scan.invalid_records
      assert_equal 1, scan.records.length
      attempt = scan.records.fetch(0)
      assert_match(
        /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
        attempt.attempt_id
      )
      assert_equal primary_decision.fetch("attempt_id"),
                   attempt.attempt_id
      assert_equal "terminal", attempt.state
      assert_equal "succeeded", attempt.outcome
      assert attempt.module_hook?
      assert_kind_of Hash, attempt.wrapper
      assert_kind_of Hash, attempt.worker
      assert Hive::Attempts::OutputReference.verify(
        attempt.receipt.fetch("log_reference"),
        root: result.attempts_root
      )

      comparator = Hive::Modules::Migration::ShadowComparator.new(
        root: File.join(
          result.hive_state_path, "module-runtime", "migration", "shadow"
        )
      )
      assert_equal [ result.comparator_record ],
                   comparator.each_record("patrol").to_a
      assert_equal true, result.comparator_record.fetch("comparable")
      assert_equal "legacy_mutator_capture",
                   result.comparator_record.fetch("evidence_source")
      assert_empty result.comparator_record.fetch("unexplained_differences")
      assert_empty result.comparator_record.fetch("duplicate_effects")

      index = result.effect_index
      assert_equal 4, index.legacy_count
      assert_equal 0, index.module_count
      assert_empty index.duplicate_keys
      targets = index.entries.map { |entry| entry.fetch("target") }
      assert_includes targets, "dismissed"
      assert_includes targets, "state"
      assert_equal 1, targets.grep(%r{\Afeatures/}).length
      assert_equal 1, targets.grep(%r{\Aruns/selection-}).length

      assert_oracle_owned_fields_absent(row)
      validated = ACTUALS.from_h(
        "schema" => ACTUALS::SCHEMA,
        "schema_version" => ACTUALS::SCHEMA_VERSION,
        "actuals" => [ row ]
      )
      assert_equal row, validated.actuals.fetch(0)
    end
  end

  def test_reproduces_semantic_identities_under_distinct_sandbox_roots
    %w[
      new_commit partial_failure restart same_commit timer_due timer_not_due
      timer_reset_reload
    ].each do |operation|
      with_tmp_dir do |first_root|
        with_tmp_dir do |second_root|
          first = run_driver(
            first_root,
            operation: operation
          ).observation
          second = run_driver(
            second_root,
            operation: operation
          ).observation

          assert_equal semantic_observation(first),
                       semantic_observation(second),
                       operation
        end
      end
    end
  end

  def test_drives_supported_schedule_operations_through_real_patrol_state
    cases = {
      "timer_not_due" => {
        trigger: "timer",
        timer_due: false,
        branch_changed: nil,
        rationale: "not_due",
        outcome_class: "not_dispatched",
        effects: 0
      },
      "same_commit" => {
        trigger: "new_commits",
        timer_due: nil,
        branch_changed: false,
        rationale: "not_due",
        outcome_class: "not_dispatched",
        effects: 0
      },
      "new_commit" => {
        trigger: "new_commits",
        timer_due: nil,
        branch_changed: true,
        rationale: "due",
        outcome_class: "completed",
        effects: 5
      },
      "timer_reset_reload" => {
        trigger: "timer",
        timer_due: false,
        branch_changed: nil,
        rationale: "not_due",
        outcome_class: "not_dispatched",
        effects: 0
      },
      "restart" => {
        trigger: "timer",
        timer_due: true,
        branch_changed: nil,
        rationale: "due",
        outcome_class: "completed",
        effects: 4
      }
    }

    cases.each do |operation, expected|
      with_tmp_dir do |sandbox|
        result = run_driver(sandbox, operation: operation)
        row = result.observation
        capture = capture_for(row)

        assert_equal expected.fetch(:trigger),
                     capture.selection_input.fetch("trigger"),
                     operation
        assert_expected(
          expected.fetch(:timer_due),
          capture.selection_input.fetch("timer_due"),
          operation
        )
        assert_expected(
          expected.fetch(:branch_changed),
          capture.selection_input.fetch("branch_changed"),
          operation
        )
        assert_equal expected.fetch(:rationale),
                     capture.selection.rationale,
                     operation
        assert_equal expected.fetch(:outcome_class),
                     capture.outcome_class,
                     operation
        assert_equal expected.fetch(:effects),
                     result.effect_index.legacy_count,
                     operation
        assert_equal "launch",
                     row.dig("decisions", 0, "outcome"),
                     operation
        assert_equal "admitted",
                     row.dig("decisions", 0, "reason"),
                     operation
        assert_oracle_owned_fields_absent(row, operation)
      end
    end
  end

  def test_positive_fixture_uses_real_reviewer_and_reproducible_finding_ids
    with_tmp_dir do |first_root|
      with_tmp_dir do |second_root|
        first_result = run_driver(
          first_root,
          operation: "ordinary_positive_fixture",
          findings: [ positive_finding ]
        )
        second_result = run_driver(
          second_root,
          operation: "ordinary_positive_fixture",
          findings: [ positive_finding ]
        )
        first = first_result.observation
        second = second_result.observation
        first_capture = capture_for(first)
        second_capture = capture_for(second)

        assert_equal "completed", first_capture.outcome_class
        assert_equal "due", first_capture.selection.rationale
        assert_equal 1, first_capture.outcome.fetch("findings")
        assert_equal 1,
                     first_capture.outcome.fetch("finding_ids").length
        assert_equal first_capture.outcome.fetch("finding_ids"),
                     second_capture.outcome.fetch("finding_ids")
        assert_equal 5, first_result.effect_index.legacy_count
        assert_equal semantic_observation(first),
                     semantic_observation(second)
      end
    end
  end

  def test_partial_failure_uses_real_reviewer_failure_and_durable_error_log
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        operation: "partial_failure"
      )
      row = result.observation
      capture = capture_for(row)

      assert_equal "due", capture.selection.rationale
      assert_equal "completed", capture.outcome_class
      assert_equal false,
                   capture.outcome.fetch("review_complete")
      assert_equal 0,
                   capture.outcome.fetch("features_reviewed")
      assert_equal 0, capture.outcome.fetch("findings")
      assert_equal [], capture.outcome.fetch("finding_ids")
      assert_equal 5, result.effect_index.legacy_count
      error_path = File.join(
        result.hive_state_path,
        "patrol",
        "runs",
        "review-error-qualification.json"
      )
      error = JSON.parse(File.binread(error_path))
      assert_equal "agent_failed", error.fetch("error")
      assert_equal "qualification reviewer partial failure",
                   error.fetch("message")
      refute row.key?("decision_class")
    end
  end

  def test_clean_fixture_reviews_real_content_without_a_finding
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        operation: "ordinary_clean_fixture"
      )
      capture = capture_for(result.observation)

      assert_equal "due", capture.selection.rationale
      assert_equal "completed", capture.outcome_class
      assert_equal true,
                   capture.outcome.fetch("review_complete")
      assert_equal 1,
                   capture.outcome.fetch(
                     "features_review_attempted"
                   )
      assert_equal 1,
                   capture.outcome.fetch("features_reviewed")
      assert_equal 0, capture.outcome.fetch("findings")
      assert_empty capture.outcome.fetch("finding_ids")
    end
  end

  def test_capacity_and_daily_quota_deferrals_use_real_token_budget
    {
      "capacity_deferral" => "cycle_agent_spawn_limit",
      "quota_deferral" => "daily_agent_spawn_limit"
    }.each do |operation, reason|
      with_tmp_dir do |sandbox|
        result = run_driver(sandbox, operation: operation)
        capture = capture_for(result.observation)

        assert_equal "due", capture.selection.rationale,
                     operation
        assert_equal "completed", capture.outcome_class,
                     operation
        assert_equal false,
                     capture.outcome.fetch(
                       "review_complete"
                     ),
                     operation
        assert_equal 1,
                     capture.outcome.fetch(
                       "features_review_attempted"
                     ),
                     operation
        assert_equal 0,
                     capture.outcome.fetch(
                       "features_reviewed"
                     ),
                     operation
        assert_equal reason,
                     capture.outcome.fetch(
                       "review_exhaustion_reason"
                     ),
                     operation
        assert_equal 0, capture.outcome.fetch("findings"),
                     operation
      end
    end
  end

  def test_drives_architecture_positive_control_through_detached_module_hook
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        module_name: "architecture-patrol",
        operation: "architecture_positive_fixture",
        findings: [ architecture_thesis ]
      )
      row = result.observation
      capture = capture_for(row)

      assert_equal "architecture-patrol", row.fetch("module")
      assert_equal "complete", capture.outcome_class
      assert capture.outcome.fetch("complete")
      assert_equal 1, capture.outcome.fetch("action_count")
      assert_equal 1,
                   capture.outcome
                     .fetch("action_outcomes")
                     .length
      assert_equal "actions",
                   row.dig("event", "payload", "target_hook")
      assert_equal(
        [ "admitted" ],
        row.fetch("decisions").map do |decision|
          decision.fetch("reason")
        end
      )
      assert_equal(
        [ "actions" ],
        row.fetch("decisions").map do |decision|
          decision.fetch("hook")
        end
      )
      assert_equal(
        [ "succeeded" ],
        row.fetch("attempts").map do |attempt|
          attempt.fetch("outcome")
        end
      )
      assert result.comparator_record.fetch("comparable")
      assert_empty result.comparator_record.fetch(
        "unexplained_differences"
      )
      assert_empty result.comparator_record.fetch(
        "duplicate_effects"
      )
      assert_empty result.comparator_record.fetch(
        "module_effects"
      )
      assert_operator result.effect_index.legacy_count, :>, 0
      assert_equal 0, result.effect_index.module_count
    end
  end

  def test_drives_architecture_clean_control_through_discovery_hook
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        module_name: "architecture-patrol",
        operation: "architecture_positive_fixture"
      )
      row = result.observation
      capture = capture_for(row)

      assert_equal "architecture-patrol", row.fetch("module")
      assert_equal "complete", capture.outcome_class
      assert capture.outcome.fetch("complete")
      assert_equal "no_theses",
                   capture.outcome.fetch("zero_reason")
      assert_equal 0, capture.outcome.fetch("action_count")
      assert_empty capture.outcome.fetch("action_outcomes")
      assert_equal "scheduled-discovery",
                   row.dig("event", "payload", "target_hook")
      assert_equal(
        [ "scheduled-discovery" ],
        row.fetch("decisions").map do |decision|
          decision.fetch("hook")
        end
      )
      assert_equal(
        [ "succeeded" ],
        row.fetch("attempts").map do |attempt|
          attempt.fetch("outcome")
        end
      )
      assert result.comparator_record.fetch("comparable")
      assert_empty result.comparator_record.fetch(
        "unexplained_differences"
      )
    end
  end

  def test_routes_live_review_content_only_through_the_provider_client
    ordinary = RecordingProviderClient.new(
      "ordinary_findings" => {
        "findings" => [ positive_finding ]
      }
    )
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        operation: "ordinary_positive_fixture",
        findings: [ positive_finding ],
        provider_client: ordinary
      )

      assert_equal "completed",
                   capture_for(result.observation).outcome_class
      assert_equal 1,
                   capture_for(result.observation)
                     .outcome.fetch("findings")
    end
    assert_equal [ "ordinary_findings" ],
                 ordinary.calls.map { |row| row.fetch(:kind) }
    assert ordinary.calls.fetch(0).fetch(:prompt).bytesize.positive?
    assert_empty ordinary.calls.fetch(0).fetch(:context_refs)

    architecture = RecordingProviderClient.new(
      "architecture_theses" => {
        "theses" => [ architecture_thesis ]
      }
    )
    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        module_name: "architecture-patrol",
        operation: "architecture_positive_fixture",
        findings: [ architecture_thesis ],
        provider_client: architecture
      )

      assert_equal "complete",
                   capture_for(result.observation).outcome_class
      assert_equal 1,
                   capture_for(result.observation)
                     .outcome.fetch("action_count")
    end
    assert_equal [ "architecture_theses" ],
                 architecture.calls.map { |row| row.fetch(:kind) }
    assert architecture.calls.fetch(0)
      .fetch(:prompt).bytesize.positive?
    assert_empty architecture.calls.fetch(0).fetch(:context_refs)
  end

  def test_rejects_architecture_faults_until_their_real_boundaries_exist
    with_tmp_dir do |sandbox|
      error = assert_raises(Hive::ConfigError) do
        driver(
          sandbox,
          module_name: "architecture-patrol",
          operation: "architecture_positive_fixture",
          findings: [ architecture_thesis ],
          faults: [ "after_legacy_capture" ]
        ).call
      end
      assert_match(/scenario is unsupported/, error.message)
    end
  end

  def test_concurrent_duplicate_delivery_keeps_one_attempt_and_explainable_skips
    with_tmp_dir do |sandbox|
      result =
        run_driver(
          sandbox,
          operation: "concurrent_duplicate_delivery"
        )
      row = result.observation

      assert_equal(
        [ "admitted", "duplicate", "duplicate" ],
        row.fetch("decisions")
          .map { |decision| decision.fetch("reason") }
      )
      assert_equal 1, row.fetch("attempts").length
      assert_equal "succeeded",
                   row.dig("attempts", 0, "outcome")
      assert_oracle_owned_fields_absent(row)
      assert_empty result.comparator_record.fetch(
        "duplicate_effects"
      )
      assert_empty result.effect_index.duplicate_keys
    end
  end

  def test_launch_failure_and_cooldown_retry_use_the_real_one_hour_retry_path
    %w[launch_failure cooldown_retry].each do |operation|
      with_tmp_dir do |sandbox|
        row =
          run_driver(
            sandbox,
            operation: operation
          ).observation

        assert_equal(
          [ "launch_handoff_failed" ],
          row.fetch("decisions")
            .map { |decision| decision.fetch("reason") },
          operation
        )
        assert_equal %w[lost terminal],
                     row.fetch("attempts")
                       .map { |attempt| attempt.fetch("state") },
                     operation
        assert_equal [ 0, 1 ],
                     row.fetch("attempts")
                       .map { |attempt|
                         attempt.fetch("retry_charge")
                       },
                     operation
        assert_oracle_owned_fields_absent(row, operation)
      end
    end
  end

  def test_after_module_decision_fault_recovers_through_the_real_retry_lineage
    skip "POSIX fork unavailable" unless Process.respond_to?(:fork)

    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        faults: [ "after_module_decision" ]
      )
      row = result.observation
      assert_oracle_owned_fields_absent(row)
      assert_equal %w[lost terminal],
                   row.fetch("attempts").map { |attempt|
                     attempt.fetch("state")
                   }
      assert_equal [ 0, 1 ],
                   row.fetch("attempts").map { |attempt|
                     attempt.fetch("retry_charge")
                   }
      assert_equal "succeeded",
                   row.fetch("attempts").last.fetch("outcome")
      assert_equal [ "admitted", "duplicate" ],
                   row.fetch("decisions").map { |decision|
                     decision.fetch("reason")
                   }
      assert_nil row.fetch("decisions").last.fetch("attempt_id")
      assert_empty result.comparator_record.fetch(
        "duplicate_effects"
      )
      assert_empty result.effect_index.duplicate_keys
    end
  end

  def test_legacy_capture_and_decision_faults_recover_from_fresh_schedulers
    skip "POSIX fork unavailable" unless Process.respond_to?(:fork)

    %w[
      after_legacy_capture after_legacy_decision
    ].each do |fault|
      with_tmp_dir do |sandbox|
        result = run_driver(sandbox, faults: [ fault ])
        row = result.observation

        assert_oracle_owned_fields_absent(row, fault)
        assert_equal "completed",
                     capture_for(row).outcome_class,
                     fault
        assert_equal 1,
                     Hive::Modules::EventLedger.new(
                       root: File.join(
                         result.hive_state_path,
                         "module-runtime"
                       )
                     ).all.length,
                     fault
        assert_empty result.comparator_record.fetch(
          "duplicate_effects"
        )
        assert_empty result.effect_index.duplicate_keys
      end
    end
  end

  def test_effect_intent_and_reconciliation_faults_recover_exactly_once
    skip "POSIX fork unavailable" unless Process.respond_to?(:fork)

    {
      "after_effect_intent" => "committed",
      "during_reconciliation" => "reconciled"
    }.each do |fault, expected_receipt_status|
      with_tmp_dir do |sandbox|
        result = run_driver(sandbox, faults: [ fault ])
        row = result.observation

        assert_oracle_owned_fields_absent(row, fault)
        receipt = result.comparator_record
                        .fetch("legacy_effects")
                        .find do |candidate|
          candidate.dig("intent", "target") ==
            "fingerprints/qualification-recovery"
        end
        refute_nil receipt, fault
        assert_equal expected_receipt_status,
                     receipt.fetch("status"),
                     fault
        assert_equal 5, result.effect_index.legacy_count,
                     fault
        assert_empty result.comparator_record.fetch(
          "duplicate_effects"
        )
        assert_empty result.effect_index.duplicate_keys
      end
    end
  end

  def test_reconciliation_failure_blocks_ambiguity_then_recovers_exact_identity
    skip "POSIX fork unavailable" unless Process.respond_to?(:fork)

    with_tmp_dir do |sandbox|
      result = run_driver(
        sandbox,
        operation: "reconciliation_failure"
      )
      row = result.observation

      assert_oracle_owned_fields_absent(row)
      receipt = result.comparator_record
                      .fetch("legacy_effects")
                      .find do |candidate|
        candidate.dig("intent", "target") ==
          "fingerprints/qualification-recovery"
      end
      refute_nil receipt
      assert_equal "reconciled", receipt.fetch("status")
      assert_equal 5, result.effect_index.legacy_count
      assert_empty result.comparator_record.fetch(
        "duplicate_effects"
      )
      assert_empty result.effect_index.duplicate_keys
    end
  end

  def test_rejects_multiple_faults_in_one_candidate_case
    with_tmp_dir do |sandbox|
      error = assert_raises(Hive::ConfigError) do
        driver(
          sandbox,
          faults: %w[
            after_legacy_capture after_module_decision
          ]
        ).call
      end

      assert_match(/scenario is unsupported/, error.message)
    end
  end

  def test_rejects_a_candidate_without_both_reviewed_module_packages
    with_tmp_dir do |sandbox|
      missing = File.join(sandbox, "candidate")
      FileUtils.mkdir_p(missing)
      candidate = DRIVER.new(
        candidate_source_root: missing,
        sandbox_root: File.join(sandbox, "run"),
        project: PROJECT,
        scenario_input: scenario_input
      )

      error = assert_raises(Hive::ConfigError) do
        candidate.call
      end
      assert_match(/candidate module package/, error.message)
    end
  end

  def test_rejects_an_ambient_home_without_mutating_env_or_ambient_state
    with_tmp_dir do |ambient_home|
      with_tmp_dir do |sandbox|
        ambient_repository =
          File.join(ambient_home, "ambient-repository")
        ambient_state = File.join(ambient_home, "ambient-state")
        FileUtils.mkdir_p([ ambient_repository, ambient_state ])
        ambient_entry = {
          "hive_state_path" => ambient_state,
          "name" => PROJECT.fetch("name"),
          "path" => ambient_repository,
          "project_id" => PROJECT.fetch("project_id"),
          "real_path" => File.realpath(ambient_repository),
          "registered_at" => NOW.utc.iso8601(6),
          "registration_id" => "ambient-registry-entry",
          "repository" => PROJECT.fetch("repository"),
          "repository_identity" => PROJECT.fetch("repository")
        }
        File.binwrite(
          File.join(ambient_home, "config.yml"),
          Hive::WorkflowPackage::CanonicalYAML.dump(
            "registered_projects" => [ ambient_entry ]
          )
        )
        config_before = File.binread(
          File.join(ambient_home, "config.yml")
        )

        with_env("HIVE_HOME" => ambient_home) do
          error = assert_raises(Hive::ConfigError) do
            driver(sandbox).call
          end
          assert_match(/process home is not confined/, error.message)
          assert_equal ambient_home, ENV.fetch("HIVE_HOME")
        end

        assert_equal config_before,
                     File.binread(File.join(ambient_home, "config.yml"))
        assert_empty Dir.children(ambient_state)
        %w[attempts hive-home hive-state repository].each do |name|
          refute_path_exists File.join(sandbox, name)
        end
      end
    end
  end

  private

  def run_driver(
    sandbox,
    module_name: "patrol",
    operation: "timer_due",
    findings: [],
    faults: [],
    provider_client: nil
  )
    generation_plan =
      if faults.one?
        DRIVER::GENERATION_PLANS.fetch(faults.fetch(0))
      elsif operation == "reconciliation_failure"
        DRIVER::GENERATION_PLANS.fetch(operation)
      else
        [ nil ]
      end
    with_usage_db_path(File.join(sandbox, "usage.db")) do
      with_env(
        "HIVE_HOME" => File.join(sandbox, "hive-home")
      ) do
        generation_plan.each_with_index do |stop_after, index|
          generation = index + 1
          if stop_after
            run_stopping_generation!(
              sandbox,
              generation: generation,
              stop_after: stop_after,
              module_name: module_name,
              operation: operation,
              findings: findings,
              faults: faults,
              provider_client: provider_client
            )
            next
          end

          return driver(
            sandbox,
            generation: generation,
            stop_after: nil,
            module_name: module_name,
            operation: operation,
            findings: findings,
            faults: faults,
            provider_client: provider_client
          ).call
        end
      end
    end
    raise "qualification generation plan did not finish"
  end

  def driver(
    sandbox,
    module_name: "patrol",
    operation: "timer_due",
    findings: [],
    faults: [],
    generation: 1,
    stop_after: nil,
    provider_client: nil
  )
    DRIVER.new(
      candidate_source_root: CANDIDATE_SOURCE_ROOT,
      sandbox_root: sandbox,
      project: PROJECT,
      provider_client: provider_client,
      generation: generation,
      stop_after: stop_after,
      scenario_input: scenario_input(
        module_name: module_name,
        operation: operation,
        findings: findings,
        faults: faults
      )
    )
  end

  def scenario_input(
    module_name: "patrol",
    operation: "timer_due",
    findings: [],
    faults: []
  )
    prefix =
      module_name == "patrol" ?
        "ordinary" : "architecture"
    case_id = "#{prefix}-#{operation.tr('_', '-')}"
    INPUT.load(
      Hive::WorkflowPackage::CanonicalYAML.dump(
        "schema" => "hive-patrol-qualification-scenario",
        "schema_version" => 1,
        "case_id" => case_id,
        "module" => module_name,
        "operation" => operation,
        "clock" => NOW.utc.iso8601(6),
        "faults" => faults,
        "reviewer" => { "findings" => findings }
      ),
      expected_case_id: case_id
    )
  end

  def positive_finding
    {
      "category" => "maintainability",
      "severity" => "low",
      "confidence" => "low",
      "title" => "Qualification fixture is intentionally minimal",
      "description" =>
        "The qualification fixture provides a deterministic review finding.",
      "recommendation" =>
        "Keep this fixture confined to qualification evidence.",
      "scope" => "local",
      "contract" =>
        "The fixture remains a valid Ruby source file.",
      "impact" =>
        "This finding proves reviewer output reached durable Patrol state.",
      "root_cause" =>
        "The source fixture is deliberately small enough for exact evidence.",
      "reproduction" =>
        "Review lib/qualification_demo.rb in the qualification sandbox.",
      "validation" =>
        "Run the configured test command.",
      "validation_key" => "test",
      "evidence" => [
        {
          "file" => "lib/qualification_demo.rb",
          "line" => 2,
          "snippet" => "def self.ready? = true",
          "role" => "root_cause"
        }
      ]
    }
  end

  def architecture_thesis
    {
      "feature" => "Checkout",
      "problem" =>
        "Checkout mixes validation and payment orchestration",
      "cost" =>
        "Frequent changes touch the same file and its callers",
      "evidence" => [
        {
          "file" => "lib/checkout.rb",
          "line" => 12,
          "snippet" => "def charge_and_validate",
          "claim" =>
            "validation and payment orchestration share one method"
        }
      ],
      "proposed_refactor" =>
        "Extract payment orchestration behind a checkout boundary",
      "expected_leverage" => {
        "drivers" => [
          {
            "signal" => "churn",
            "relief" => 1,
            "mechanism" =>
              "isolate payment edits from validation code"
          }
        ]
      },
      "confidence" => "medium",
      "risk" => {
        "caps" => { "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      "required_validation" => {
        "commands" => [ "test" ],
        "characterization_first" => false,
        "notes" => "Run checkout tests"
      },
      "follow_up_approval_state" => "pending"
    }
  end

  def capture_for(row)
    Hive::Modules::Migration::PatrolCapture.from_h(
      row.dig("event", "payload", "legacy_mutator_capture")
    )
  end

  def assert_expected(expected, actual, message)
    if expected.nil?
      assert_nil actual, message
    else
      assert_equal expected, actual, message
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def semantic_observation(row)
    row.slice(
      *%w[
        case_id comparator_semantic_digest event event_id legacy_capture_id
        legacy_effect_keys module module_effect_keys repository_sha
        trigger_digest
      ]
    ).merge(
      "decisions" => row.fetch("decisions").map do |decision|
        decision.except(
          "attempt_id", "decision_id", "evaluated_at"
        )
      end,
      "attempts" => row.fetch("attempts").map do |attempt|
        attempt.slice(
          *%w[
            loss outcome ownership_generation predecessor_attempt_id
            retry_charge state subject task_generation task_input_epoch
          ]
        )
      end
    )
  end

  def run_stopping_generation!(
    sandbox,
    generation:,
    stop_after:,
    module_name:,
    operation:,
    findings:,
    faults:,
    provider_client:
  )
    pid = fork do
      driver(
        sandbox,
        generation: generation,
        stop_after: stop_after,
        module_name: module_name,
        operation: operation,
        findings: findings,
        faults: faults,
        provider_client: provider_client
      ).call
      Process.exit!(71)
    rescue StandardError
      Process.exit!(70)
    end
    _pid, status = Process.wait2(pid)
    assert status.exited?, stop_after
    assert_equal 76, status.exitstatus, stop_after
    snapshot = CHECKPOINTS.new.capture(
      sandbox_root: sandbox,
      roots: {
        "hive_home" => File.join(sandbox, "hive-home"),
        "hive_state" => File.join(sandbox, "hive-state"),
        "repository" => File.join(sandbox, "repository")
      }
    )
    verifier = CHECKPOINT_VERIFIER.new
    evidence = verifier.call(
      case_id:
        scenario_input(
          module_name: module_name,
          operation: operation,
          findings: findings,
          faults: faults
        ).case_id,
      generation: generation,
      checkpoint: stop_after,
      snapshot: snapshot,
      sandbox_root: sandbox,
      scenario_input: scenario_input(
        module_name: module_name,
        operation: operation,
        findings: findings,
        faults: faults
      )
    )
    assert_equal stop_after, evidence.checkpoint
    assert_equal snapshot.sha256, evidence.state_sha256
  ensure
    if pid
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def assert_oracle_owned_fields_absent(row, message = nil)
    ACTUALS::ORACLE_KEYS.each do |key|
      refute row.key?(key), message || key
    end
  end
end
