require "test_helper"
require "hive/commands/init"
require "hive/commands/act"
require "hive/recovery/manual_retry"
require "hive/attempts/dispatcher"
require "hive/runtime_control_plane/command_schema_installation"

class ManualWorkflowRetryTest < Minitest::Test
  include HiveTestHelper

  class Launcher
    attr_reader :launched
    attr_accessor :outcome, :before_launch

    def initialize(store, task)
      @store, @task = store, task
      @launched = []
      @outcome = "succeeded"
    end

    def preflight! = true

    def launch(record, claim_capability:)
      @launched << record
      @before_launch&.call(record)
      claimed = @store.claim(record, owner: { "pid" => Process.pid },
        claim_capability: claim_capability, first_heartbeat_timeout_sec: 30, now: Time.now.utc)
      running = @store.first_heartbeat(claimed, stale_sec: 30, now: Time.now.utc)
      Hive::Markers.set(@task.state_file, @outcome == "succeeded" ? :complete : :error,
        reason: "fixture_stage_outcome")
      @store.terminalize(running, outcome: @outcome,
        exit_status: @outcome == "succeeded" ? 0 : 1,
        final_checkpoint: running.checkpoint, output_references: [],
        log_reference: { "path" => "logs/#{record.attempt_id}.frames", "size" => 0,
          "sha256" => Digest::SHA256.hexdigest("") }, now: Time.now.utc)
      { "claimed" => true }
    end
  end

  def test_review_and_execute_retries_use_real_request_admission_and_return_terminal_outcomes
    { "6-review" => ["REVIEW_ERROR", "review_orphaned", "review"],
      "4-execute" => ["ERROR", "implementer_failed", "develop"],
      "3-plan" => ["ERROR", "timeout", "plan"] }.each do |stage, (marker, reason, verb)|
      with_retry(stage: stage, marker: marker, reason: reason) do |row, coordinator, repository, store, launcher, runner|
        receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
        assert_equal "terminal", receipt.status, receipt.to_h.inspect
        assert_equal "succeeded", receipt.terminal_outcome
        assert_equal 1, launcher.launched.size
        assert_equal verb, launcher.launched.first["worker_argv"][1]
        assert_equal receipt.request_id, launcher.launched.first["request_id"]
        assert_equal "terminal", repository.fetch(receipt.request_id).recovery["phase"]
        assert_equal :complete, Hive::Markers.current(row.fetch("state_file")).name
      end
    end
  end

  def test_generic_agent_stage_uses_the_installed_run_verb
    with_retry(stage: "4-draft", marker: "ERROR", reason: "timeout", workflow: "content") do |row, coordinator, repository, store, launcher, runner|
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "terminal", receipt.status, receipt.to_h.inspect
      assert_equal "run", launcher.launched.first["worker_argv"][1]
      assert_includes launcher.launched.first["worker_argv"], "4-draft"
    end
  end

  def test_launch_preflight_failure_preserves_a_fresh_operator_retry
    with_retry do |row, coordinator, repository, store, launcher, runner|
      launcher.define_singleton_method(:preflight!) { raise Hive::Error, "fixture launcher unavailable" }
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "unavailable", receipt.status
      assert_equal "launch_unavailable", receipt.reason
      assert_includes receipt.remediation, "fixture launcher unavailable"
      assert_empty launcher.launched
      assert_equal "cleared", repository.fetch(receipt.request_id).recovery["phase"]
      current = Hive::OperationalAction.observed_row(Hive::Task.new(row.fetch("folder")), project: row.fetch("project"))
      assert current["recovery_observation"]
      assert_equal "workflow.retry", Hive::OperationalAction.descriptor(project: row.fetch("project"), row: current).fetch("action_id")
    end
  end

  def test_keyed_failed_stage_emits_one_envelope_and_replays_without_a_second_attempt
    with_retry do |row, coordinator, repository, store, launcher, runner|
      launcher.outcome = "failed"
      task = Hive::Task.new(row.fetch("folder"))
      path = File.join(task.project_root, ".hive-state", "config.yml")
      config = YAML.safe_load(File.read(path))
      config["command_receipts"] = { "keyed_intake_enabled" => true }
      File.write(path, config.to_yaml)
      Hive::RuntimeControlPlane::CommandSchemaInstallation.install!(database: store.database,
        package_coordinates: { version: "0.0.0-test", location: "https://example.invalid/compat.gem", sha256: "a" * 64 })
      writer = Object.new
      writer.define_singleton_method(:recover!) do |**args|
        Hive::Recovery::API.recover!(**args, coordinator: coordinator, manual_retry: runner)
      end
      executor = Hive::OperationalAction::Executor.new(recovery_writer: writer)
      observation = Hive::OperationalAction.descriptor_for_task(task, project: row.fetch("project"))
      outputs = 2.times.map do
        stdout, = capture_io do
          assert_raises(Hive::TaskInErrorState) do
            Hive::Commands::Act.new("workflow.retry", observation.fetch("target"),
              observation: observation.fetch("observation_token"), json: true,
              idempotency_key: "attached-failure", executor: executor,
              command_receipt_store: Hive::CommandReceiptStore.new(database: store.database)).call
          end
        end
        payload = JSON.parse(stdout)
        assert_equal true, payload.fetch("ok")
        assert_equal "failed", payload.dig("result", "recovery", "terminal_outcome")
        assert_equal launcher.launched.first.attempt_id, payload.dig("result", "recovery", "attempt_id")
        payload
      end
      assert_equal outputs.first, outputs.last
      assert_equal 1, launcher.launched.size
    end
  end

  def test_capacity_deferral_is_restartable_with_same_request_and_one_retry_charge
    with_retry(limits: { max_global: 0 }) do |row, coordinator, repository, store, launcher, runner, dispatcher|
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "blocked", receipt.status, receipt.to_h.inspect
      refute_equal "scheduler", receipt.owner
      assert_empty launcher.launched
      task = Hive::Task.new(row.fetch("folder"))
      current = Hive::OperationalAction.observed_row(task, project: row.fetch("project"))
      assert current["recovery_observation"], current.inspect
      resumed = Hive::Recovery::ManualRetry.new(coordinator: coordinator, repository: repository,
        store: store, attempts: Hive::Attempts::API.new(daemon: dispatcher.call({ max_global: 5 })))
      terminal = resumed.call(row: current, observation_token: coordinator.observation_token_for(current))
      assert_equal "terminal", terminal.status, terminal.to_h.inspect
      assert_equal receipt.request_id, terminal.request_id
      assert_equal 1, terminal.retry_count
      assert_equal 1, launcher.launched.size
    end
  end

  def test_concurrent_consumer_uses_existing_attempt_without_allocating_a_successor
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      loser = nil
      launcher.before_launch = lambda do |record|
        request = repository.fetch(record["request_id"])
        loser = dispatcher.call({}).dispatch_request(request, interactive: false)
      end
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "terminal", receipt.status, receipt.to_h.inspect
      assert_equal :existing_live, loser.status
      assert_equal receipt.attempt_id, loser.attempt.attempt_id
      assert_equal 1, launcher.launched.size
    end
  end

  def test_changed_inputs_between_repair_and_admission_prevent_launch
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      prepared = coordinator.prepare_manual(row: Hive::Recovery::API.observation(row), observation_token: coordinator.observation_token_for(row))
      request = repository.fetch(prepared.request_id)
      File.open(row.fetch("state_file"), "a") { |file| file.puts "Changed instructions" }
      assert_raises(Hive::Attempts::RepositoryError) do
        dispatcher.call({}).dispatch_request(request, interactive: false)
      end
      assert_empty launcher.launched
      assert_empty store.active_attempts
    end
  end

  def test_abandoned_dispatched_request_terminalizes_from_canonical_attempt_without_relaunch
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      prepared = coordinator.prepare_manual(row: Hive::Recovery::API.observation(row), observation_token: coordinator.observation_token_for(row))
      request = repository.fetch(prepared.request_id)
      # Simulate caller loss after admission, before its terminal transition.
      admitted = dispatcher.call({}).dispatch_request(request, interactive: false)
      coordinator.mark_dispatched(request, attempt_id: admitted.attempt.attempt_id)
      repository.release_claim(request.request_id)
      # A launcher failure can leave the exact post-clear bytes unchanged.
      Hive::Markers.clear_current(row.fetch("state_file"), expected_name: "complete")
      current = Hive::OperationalAction.observed_row(Hive::Task.new(row.fetch("folder")), project: row.fetch("project"))
      assert current["recovery_observation"], current.inspect
      receipt = runner.call(row: current, observation_token: coordinator.observation_token_for(current))
      assert_equal "terminal", receipt.status, receipt.to_h.inspect
      assert_equal prepared.request_id, receipt.request_id
      assert_equal 1, receipt.retry_count
      assert_equal 1, launcher.launched.size
    end
  end

  private

  def with_retry(stage: "6-review", marker: "REVIEW_ERROR", reason: "review_orphaned", limits: {}, workflow: "coding")
    with_tmp_global_config do
      with_tmp_git_repo do |root|
        capture_io { Hive::Commands::Init.new(root).call }
        project = Hive::Config.registered_projects.find { |entry| entry["path"] == root }
        path = File.join(project.fetch("hive_state_path"), "config.yml")
        config = YAML.safe_load(File.read(path))
        config["daemon"] = { "enabled" => false }
        File.write(path, config.to_yaml)
        folder = File.join(project.fetch("hive_state_path"), "stages", stage, "manual-retry-task")
        FileUtils.mkdir_p(folder)
        Hive::TaskMeta.write(folder, id: 817, slug: "manual-retry-task", display_name: nil, workflow: workflow)
        task = Hive::Task.new(folder)
        File.write(task.state_file, "# Retry task\n\n#{Hive::Markers.build_marker(marker, { 'reason' => reason, 'marker_id' => 'retry-marker' })}\n")
        store = Hive::Attempts::Repository.open_default
        repository = Hive::RuntimeControlPlane::DispatchRepository.new(database: store.database)
        coordinator = Hive::Daemon::RecoveryCoordinator.new(dispatch_repository: repository, attempt_store: store)
        launcher = Launcher.new(store, task)
        dispatcher = lambda do |settings|
          Hive::Attempts::Dispatcher.new(store: store, launcher: launcher,
            task_resolver: ->(_) { task }, limits: { max_global: 5, max_per_project: 5, max_daily: 50 }.merge(settings))
        end
        runner = Hive::Recovery::ManualRetry.new(coordinator: coordinator, repository: repository,
          store: store, attempts: Hive::Attempts::API.new(daemon: dispatcher.call(limits)))
        row = Hive::OperationalAction.observed_row(task, project: project.fetch("name"))
        row["state_file_mtime"] = Time.iso8601(row.fetch("mtime"))
        row["marker_attrs"] = row.fetch("attrs")
        yield row, coordinator, repository, store, launcher, runner, dispatcher
      end
    end
  end
end
