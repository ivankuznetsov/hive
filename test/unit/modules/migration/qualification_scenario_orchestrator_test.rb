require "test_helper"
require "digest"
require "fileutils"
require "hive/modules/migration/qualification_checkpoint_evidence"
require "hive/modules/migration/qualification_scenario_orchestrator"
require "hive/modules/migration/qualification_scenario_process"

class QualificationScenarioOrchestratorTest < Minitest::Test
  include HiveTestHelper

  CHECKPOINTS =
    Hive::Modules::Migration::QualificationCheckpointEvidence
  ORCHESTRATOR =
    Hive::Modules::Migration::QualificationScenarioOrchestrator
  PROCESS_RESULT =
    Hive::Modules::Migration::QualificationScenarioProcess::Result
  EMPTY_DIGEST = Digest::SHA256.hexdigest("")

  class CandidateProcess
    attr_reader :calls

    def initialize(state_root:, overrides: {})
      @state_root = state_root
      @overrides = overrides
      @calls = []
    end

    def call(**arguments)
      @calls << arguments
      stop_after = arguments.fetch(:argv).fetch(0)
      generation = @calls.length
      FileUtils.mkdir_p(@state_root, mode: 0o700)
      File.open(
        File.join(@state_root, "generations.log"),
        "ab",
        0o600
      ) do |file|
        file.write("#{generation}:#{stop_after || 'terminal'}\n")
      end
      result(
        stop_after ? 76 : 0,
        @overrides.fetch(generation, {})
      )
    end

    private

    def result(exit_status, overrides)
      teardown = {
        "status" => "passed",
        "attempt_count" => 1,
        "custody_count" => 1,
        "live_processes" => 0,
        "kill_authority" => "host_pid_namespace"
      }.merge(overrides.fetch(:teardown, {})).freeze
      values = {
        status: exit_status.zero? ? "passed" : "failed",
        exit_status: exit_status,
        signal: nil,
        timed_out: false,
        network_isolated: true,
        stdout: stream,
        stderr: stream,
        duration_seconds: 0.1,
        executable_sha256: "1" * 64,
        ruby_sha256: "2" * 64,
        attempt_count: teardown.fetch("attempt_count"),
        custody_count: teardown.fetch("custody_count"),
        sandbox_profile_sha256: "3" * 64,
        source_inventory_sha256: "4" * 64,
        installed_inventory_sha256: "5" * 64,
        teardown: teardown
      }.merge(overrides.reject { |key, _| key == :teardown })
      PROCESS_RESULT.new(**values).freeze
    end

    def stream
      {
        "bytes" => 0,
        "sha256" => EMPTY_DIGEST,
        "truncated" => false
      }.freeze
    end
  end

  def test_runs_one_terminal_generation_without_a_fault
    with_harness do |context|
      result = run_orchestrator(context, recovery_plan: nil)

      assert_equal 1, result.generation_count
      assert_equal 0, result.restart_count
      assert_equal 1, context.fetch(:process).calls.length
      assert_nil(
        context.fetch(:process).calls.fetch(0).fetch(:argv).fetch(0)
      )
      assert_equal "completed", result.receipts.fetch(0).kind
      assert_equal "a" * 64, result.final_output_sha256
      assert result.frozen?
      assert result.to_h.frozen?
      assert result.generations.all?(&:frozen?)
      assert result.receipts.all?(&:frozen?)
    end
  end

  def test_runs_each_public_fault_as_checkpoint_then_completion
    ORCHESTRATOR::TWO_GENERATION_CHECKPOINTS.each do |fault|
      with_harness do |context|
        result = run_orchestrator(
          context,
          recovery_plan: fault
        )

        assert_equal 2, result.generation_count, fault
        assert_equal 1, result.restart_count, fault
        assert_equal(
          [ fault, nil ],
          context.fetch(:process).calls.map do |arguments|
            arguments.fetch(:argv).fetch(0)
          end,
          fault
        )
        assert_equal(
          %w[checkpointed completed],
          result.receipts.map(&:kind),
          fault
        )
      end
    end
  end

  def test_during_reconciliation_uses_three_bounded_generations
    with_harness do |context|
      result = run_orchestrator(
        context,
        recovery_plan: "during_reconciliation"
      )

      assert_equal 3, result.generation_count
      assert_equal 2, result.restart_count
      assert_equal(
        [
          "before_effect_settlement",
          "during_reconciliation",
          nil
        ],
        context.fetch(:process).calls.map do |arguments|
          arguments.fetch(:argv).fetch(0)
        end
      )
      assert_equal(
        result.receipts.fetch(0).sha256,
        result.receipts.fetch(1).predecessor_sha256
      )
      assert_equal(
        result.receipts.fetch(1).sha256,
        result.receipts.fetch(2).predecessor_sha256
      )
      assert_nil result.receipts.fetch(0).predecessor_sha256
      assert_equal(
        result.generations.fetch(0).after_snapshot.sha256,
        result.generations.fetch(1).before_snapshot.sha256
      )
      assert_equal(
        result.generations.fetch(1).after_snapshot.sha256,
        result.generations.fetch(2).before_snapshot.sha256
      )
    end
  end

  def test_reconciliation_failure_is_a_three_generation_internal_plan
    with_harness do |context|
      result = run_orchestrator(
        context,
        recovery_plan: "reconciliation_failure"
      )

      assert_equal "reconciliation_failure",
                   result.recovery_plan
      assert_equal 3, result.generation_count
      assert_equal(
        [
          "before_effect_settlement",
          "reconciliation_failure",
          nil
        ],
        context.fetch(:process).calls.map do |arguments|
          arguments.fetch(:argv).fetch(0)
        end
      )
      assert_equal(
        %w[checkpointed checkpointed completed],
        result.receipts.map(&:kind)
      )
    end
  end

  def test_rejects_unexpected_process_outcomes
    [
      [ nil, { 1 => { exit_status: 76, status: "failed" } } ],
      [
        "after_legacy_capture",
        { 1 => { exit_status: 0, status: "passed" } }
      ],
      [ nil, { 1 => { timed_out: true, status: "failed" } } ],
      [
        nil,
        {
          1 => {
            teardown: { "live_processes" => 1 }
          }
        }
      ]
    ].each do |recovery_plan, overrides|
      with_harness(overrides: overrides) do |context|
        assert_malformed do
          run_orchestrator(
            context,
            recovery_plan: recovery_plan
          )
        end
      end
    end
  end

  def test_rejects_process_identity_drift_between_generations
    overrides = {
      2 => { executable_sha256: "9" * 64 }
    }
    with_harness(overrides: overrides) do |context|
      assert_malformed do
        run_orchestrator(
          context,
          recovery_plan: "after_legacy_decision"
        )
      end
    end
  end

  def test_rejects_state_changed_between_owned_generations
    with_harness do |context|
      prepare = context.fetch(:prepare)
      calls = 0
      tampering_prepare = lambda do |**arguments|
        calls += 1
        if calls == 2
          File.binwrite(
            File.join(context.fetch(:state), "outside-write"),
            "tampered"
          )
          File.chmod(
            0o600,
            File.join(context.fetch(:state), "outside-write")
          )
        end
        prepare.call(**arguments)
      end

      assert_malformed do
        run_orchestrator(
          context,
          recovery_plan: "after_module_decision",
          prepare: tampering_prepare
        )
      end
    end
  end

  def test_rejects_stale_checkpoint_evidence
    with_harness do |context|
      stale_snapshot = nil
      validator = lambda do |checkpoint:, before_snapshot:, **|
        stale_snapshot ||= before_snapshot
        context.fetch(:evidence).bind(
          checkpoint: checkpoint,
          snapshot: stale_snapshot,
          facts: { "verified" => true }
        )
      end

      assert_malformed do
        run_orchestrator(
          context,
          recovery_plan: "after_effect_intent",
          verify: validator
        )
      end
    end
  end

  def test_result_round_trip_rejects_a_tampered_receipt_chain
    with_harness do |context|
      result = run_orchestrator(
        context,
        recovery_plan: "after_legacy_capture"
      )

      loaded = ORCHESTRATOR::Result.from_h(result.to_h)
      assert_equal result.to_h, loaded.to_h

      tampered = mutable(result.to_h)
      tampered["generations"]
        .fetch(1)
        .fetch("receipt")["predecessor_receipt_sha256"] = "f" * 64
      assert_malformed { ORCHESTRATOR::Result.from_h(tampered) }
    end
  end

  private

  def with_harness(overrides: {})
    with_tmp_dir do |directory|
      sandbox = File.join(directory, "sandbox")
      state = File.join(sandbox, "state")
      FileUtils.mkdir_p(state, mode: 0o700)
      process = CandidateProcess.new(
        state_root: state,
        overrides: overrides
      )
      evidence = CHECKPOINTS.new
      prepare = lambda do |generation:, stop_after:|
        {
          request_sha256:
            Digest::SHA256.hexdigest(
              "#{generation}:#{stop_after || 'terminal'}"
            ),
          process_arguments: process_arguments(
            sandbox,
            stop_after
          )
        }
      end
      context = {
        sandbox: sandbox,
        state: state,
        roots: {
          "attempts" => File.join(sandbox, "attempts"),
          "state" => state
        },
        process: process,
        evidence: evidence,
        prepare: prepare
      }
      yield context
    end
  end

  def run_orchestrator(
    context,
    recovery_plan:,
    prepare: nil,
    verify: nil
  )
    evidence = context.fetch(:evidence)
    verifier = verify || lambda do |checkpoint:, generation:,
                                   after_snapshot:, **|
      evidence.bind(
        checkpoint: checkpoint,
        snapshot: after_snapshot,
        facts: {
          "generation" => generation,
          "verified" => true
        }
      )
    end
    ORCHESTRATOR.new(
      process: context.fetch(:process),
      checkpoint_evidence: evidence
    ).call(
      case_id: "case-one",
      recovery_plan: recovery_plan,
      sandbox_root: context.fetch(:sandbox),
      state_roots: context.fetch(:roots),
      timeout_seconds: 30,
      prepare_generation: prepare || context.fetch(:prepare),
      verify_checkpoint: verifier,
      final_output_sha256: ->(**) { "a" * 64 }
    )
  end

  def process_arguments(sandbox, stop_after)
    {
      executable: File.join(sandbox, "candidate"),
      argv: [ stop_after ],
      workspace: File.join(sandbox, "workspace"),
      source_root: File.join(sandbox, "source"),
      installed_root: File.join(sandbox, "installed"),
      case_root: sandbox,
      request_ref: "/qualification/request.json",
      scenario_ref: "/qualification/scenario.json",
      network: false,
      credentials: [],
      hive_home: File.join(sandbox, "hive-home")
    }
  end

  def mutable(value)
    Marshal.load(Marshal.dump(value))
  end

  def assert_malformed
    error = assert_raises(Hive::ConfigError) { yield }
    assert_equal(
      "patrol qualification process generations are malformed",
      error.message
    )
  end
end
