require "test_helper"
require "hive/commands/init"
require "hive/commands/act"
require "hive/recovery/manual_retry"
require "hive/attempts/dispatcher"
require "hive/operational_status"
require "hive/daemon/dispatcher"
require "json_schemer"
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
    { "6-review" => [ "REVIEW_ERROR", "review_orphaned", "review" ],
      "4-execute" => [ "ERROR", "implementer_failed", "develop" ],
      "3-plan" => [ "ERROR", "timeout", "plan" ] }.each do |stage, (marker, reason, verb)|
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

  def test_no_provider_route_is_unavailable_and_retains_a_guarded_request
    policy = Hive::ProviderRouting::Policy.explicit(stage: "review", routes: [],
      requirements: Hive::ProviderRouting::Requirements.empty, pin: nil, account_policy: {})
    with_retry(policy: policy) do |row, coordinator, repository, store, launcher, runner|
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "unavailable", receipt.status
      assert_equal "provider", receipt.owner
      assert_equal "no_eligible_provider_route", receipt.reason
      assert_empty launcher.launched
      assert_empty store.active_attempts
      request = repository.fetch(receipt.request_id)
      assert_equal "cleared", request.recovery["phase"]
      projected = coordinator.projected_receipt_for_request(request, dispatch_enabled: false)
      assert_equal "provider", projected.owner
      assert_equal "unavailable", projected.status
      assert_equal 1, projected.retry_count
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

  def test_action_observations_reuse_configuration_and_coordinator_but_refresh_requests_and_markers
    with_retry do |row, coordinator|
      task = Hive::Task.new(row.fetch("folder"))
      context = Hive::OperationalAction::ObservationContext.new
      config = Hive::Config.load(task.project_root)
      config_reads = 0
      coordinator_opens = 0
      evidence_reads = 0
      coordinator.define_singleton_method(:manual_evidence) do |**|
        evidence_reads += 1
        evidence_reads == 1 ? nil : { "binding" => { "request_id" => "request-live" }, "receipt" => { "status" => "running" } }
      end
      with_replaced_singleton_method(Hive::Config, :load, lambda { |*|
        config_reads += 1
        config
      }) do
        with_replaced_singleton_method(Hive::Daemon::RecoveryCoordinator, :new, lambda { |**|
          coordinator_opens += 1
          coordinator
        }) do
          first = Hive::OperationalAction.observed_row(task, project: row.fetch("project"), context: context)
          assert Hive::OperationalAction.descriptor(project: row.fetch("project"), row: first)
          Hive::Markers.clear_current(task.state_file, expected_name: "review_error")
          second = Hive::OperationalAction.observed_row(task, project: row.fetch("project"), context: context)
          assert_equal "none", second.fetch("marker")
          assert_equal "request-live", second.dig("recovery_observation", "request_id")
          assert_nil Hive::OperationalAction.descriptor(project: row.fetch("project"), row: second)
        end
      end
      assert_equal 1, config_reads
      assert_equal 1, coordinator_opens
      assert_equal 2, evidence_reads
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
        assert_equal "failed", payload.dig("command_receipt", "state")
        durable = Hive::CommandReceiptStore.new(database: store.database).receipt(payload.dig("command_receipt", "id"))
        assert_equal "failed", durable.fetch(:state)
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, durable.fetch(:result_status)
        assert_equal 0, durable.fetch(:retry_eligible), "applied failure must never authorize resubmission"
        payload
      end
      assert_equal outputs.first, outputs.last
      assert_equal 1, launcher.launched.size
    end
  end

  def test_caller_detachment_preserves_the_admitted_attempt_for_fresh_attachment
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        @launched << record
        { "claimed" => true }
      end
      client = Object.new
      client.define_singleton_method(:attach) do |attempt_id, **|
        Hive::Attempts::ClientResult.new(status: :detached, exit_status: 130,
          outcome: nil, receipt: nil, attempt_id: attempt_id)
      end
      attached = Hive::Recovery::ManualRetry.new(coordinator: coordinator, repository: repository,
        store: store, attempts: Hive::Attempts::API.new(daemon: dispatcher.call({})), client: client)
      first = attached.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "running", first.status
      assert_equal "agent", first.owner
      assert_equal "caller_detached", first.reason
      current = Hive::OperationalAction.observed_row(Hive::Task.new(row.fetch("folder")), project: row.fetch("project"))
      assert_equal "running", current.dig("manual_recovery_receipt", "status")
      assert_nil Hive::OperationalAction.descriptor_for_task(Hive::Task.new(row.fetch("folder")), project: row.fetch("project"))
      second = attached.call(row: current, observation_token: coordinator.observation_token_for(current))
      assert_equal first.attempt_id, second.attempt_id
      assert_equal "dispatched", repository.fetch(first.request_id).recovery["phase"]
      assert_equal 1, launcher.launched.size
      assert_equal 1, store.active_attempts.size
    end
  end

  def test_terminal_receipt_wins_a_caller_detachment_race
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      client = Object.new
      client.define_singleton_method(:attach) do |attempt_id, **|
        Hive::Attempts::ClientResult.new(status: :detached, exit_status: 130,
          outcome: nil, receipt: nil, attempt_id: attempt_id)
      end
      attached = Hive::Recovery::ManualRetry.new(coordinator: coordinator, repository: repository,
        store: store, attempts: Hive::Attempts::API.new(daemon: dispatcher.call({})), client: client)
      receipt = attached.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "terminal", receipt.status
      assert_equal "succeeded", receipt.terminal_outcome
      assert_equal 1, launcher.launched.size
    end
  end

  def test_lost_attempt_reports_canonical_loss_and_repairs_the_unchanged_failure_marker
    with_retry do |row, coordinator, repository, store, launcher, runner|
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        @launched << record
        store.mark_lost(record, reason: "fixture_owner_gone", now: Time.now.utc)
        { "claimed" => true }
      end
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "terminal", receipt.status
      assert_equal "lost", receipt.terminal_outcome
      assert_equal store.fetch(receipt.attempt_id)["ended_at"], receipt.terminal_at
      assert_equal "recovery_attempt_failed", Hive::Markers.current(row.fetch("state_file")).attrs["reason"]
      assert_equal 1, launcher.launched.size
    end
  end

  def test_caller_loss_before_dispatch_phase_reconciles_a_lost_attempt_without_relaunch
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      prepared = coordinator.prepare_manual(row: Hive::Recovery::API.observation(row),
        observation_token: coordinator.observation_token_for(row))
      request = repository.fetch(prepared.request_id)
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        @launched << record
        store.mark_lost(record, reason: "fixture_owner_gone", now: Time.now.utc)
        { "claimed" => true }
      end
      dispatcher.call({}).dispatch_request(request, interactive: false)
      current = Hive::OperationalAction.observed_row(Hive::Task.new(row.fetch("folder")), project: row.fetch("project"))
      receipt = runner.call(row: current, observation_token: coordinator.observation_token_for(current))
      assert_equal "terminal", receipt.status
      assert_equal "lost", receipt.terminal_outcome
      assert_equal request.request_id, receipt.request_id
      assert_equal 1, receipt.retry_count
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
      daemon = Hive::Daemon::Dispatcher.allocate
      daemon.instance_variable_set(:@dispatch_repository, repository)
      daemon.instance_variable_set(:@attempt_dispatcher, Hive::Attempts::API.new(daemon: dispatcher.call({})))
      daemon.instance_variable_set(:@recovery_coordinator, coordinator)
      logger = Object.new
      logger.define_singleton_method(:event) { |*_, **_| }
      daemon.instance_variable_set(:@logger, logger)
      launcher.before_launch = lambda do |record|
        request = repository.fetch(record["request_id"])
        assert daemon.send(:explicit_action_recovery?, request)
        loser = daemon.send(:dispatch_request!, request, now: Time.now.utc)
      end
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "terminal", receipt.status, receipt.to_h.inspect
      assert_equal :existing_live, loser.status
      assert_equal receipt.attempt_id, loser.attempt.attempt_id
      assert_equal 1, launcher.launched.size
    end
  end

  def test_foreign_existing_live_admission_never_binds_manual_recovery_in_either_consumer
    %i[manual daemon].each do |consumer|
      with_retry(stage: "3-plan", marker: "ERROR", reason: "timeout") do |row, coordinator, repository, store, launcher, runner, dispatcher|
        task = Hive::Task.new(row.fetch("folder"))
        prepared = coordinator.prepare_manual(row: Hive::Recovery::API.observation(row),
          observation_token: coordinator.observation_token_for(row))
        request = repository.fetch(prepared.request_id)
        launch = launcher.method(:launch)
        foreign_capability = nil
        launcher.define_singleton_method(:launch) do |record, claim_capability:|
          @launched << record
          foreign_capability = claim_capability
          { "claimed" => true }
        end
        # An owner command wins after repair, before recovery admission, using
        # the same task/stage/generation but a different command progress token.
        foreign_request = request.with(request_id: "foreign-run", recovery: nil,
          argv: [ "hive", "plan-review-run", request.slug,
            "--project", request.project, "--json" ])
        admission = dispatcher.call({})
        foreign = admission.dispatch_request(foreign_request, interactive: false).attempt
        refute coordinator.manual_attempt_matches?(request, foreign)
        api = Hive::Attempts::API.new(daemon: admission)
        api.define_singleton_method(:attach) { |*, **| raise "must not attach to foreign work" }

        if consumer == :manual
          attached = Hive::Recovery::ManualRetry.new(coordinator: coordinator,
            repository: repository, attempts: api)
          current = Hive::OperationalAction.observed_row(task, project: row.fetch("project"))
          receipt = attached.call(row: current, observation_token: coordinator.observation_token_for(current))
          assert_equal "unavailable", receipt.status, receipt.to_h.inspect
          assert_equal "attempt_identity_conflict", receipt.reason
          assert_nil receipt.attempt_id
        else
          daemon = Hive::Daemon::Dispatcher.allocate
          daemon.instance_variable_set(:@dispatch_repository, repository)
          daemon.instance_variable_set(:@attempt_dispatcher, api)
          daemon.instance_variable_set(:@recovery_coordinator, coordinator)
          daemon.instance_variable_set(:@dispatch_request_log_signatures, {})
          logger = Object.new
          logger.define_singleton_method(:event) { |*, **| }
          daemon.instance_variable_set(:@logger, logger)
          result = daemon.send(:dispatch_request!, request, now: Time.now.utc)
          assert_equal :deferred, result.status
          assert_equal "attempt_identity_conflict", result.reason
        end

        current_request = repository.fetch(request.request_id)
        assert_equal "cleared", current_request.recovery["phase"]
        assert_nil current_request.recovery["attempt_id"]
        assert_nil repository.recovery_attempt_id(request.request_id)
        assert_equal foreign.to_h, store.fetch(foreign.attempt_id).to_h, "foreign work must remain untouched"
        assert_equal 1, launcher.launched.size

        claimed = store.claim(foreign, owner: { "pid" => Process.pid },
          claim_capability: foreign_capability, first_heartbeat_timeout_sec: 30, now: Time.now.utc)
        running = store.first_heartbeat(claimed, stale_sec: 30, now: Time.now.utc)
        store.terminalize(running, outcome: "failed", exit_status: 1,
          final_checkpoint: running.checkpoint, output_references: [],
          log_reference: { "path" => "logs/#{foreign.attempt_id}.frames", "size" => 0,
            "sha256" => Digest::SHA256.hexdigest("") }, now: Time.now.utc)
        launcher.define_singleton_method(:launch, launch)
        current = Hive::OperationalAction.observed_row(task, project: row.fetch("project"))
        action = Hive::OperationalAction.descriptor(project: row.fetch("project"), row: current)
        assert_equal "workflow.retry", action.fetch("action_id")
        receipt = runner.call(row: current, observation_token: action.fetch("observation_token"))
        assert_equal "terminal", receipt.status, receipt.to_h.inspect
        assert_equal "succeeded", receipt.terminal_outcome
        assert_equal request.request_id, receipt.request_id
        assert_equal 1, receipt.retry_count
        assert_equal 2, launcher.launched.size
      end
    end
  end

  def test_two_consumers_reaching_admission_together_launch_once_in_either_winner_order
    %i[manual competitor].each do |winner|
      with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
        arrivals = Queue.new
        create = store.method(:create_launching)
        store.define_singleton_method(:create_launching) do |**attributes|
          gate = Queue.new
          arrivals << [ Thread.current[:consumer], gate ]
          gate.pop
          create.call(**attributes)
        end
        threads = {}
        gates = {}
        begin
          threads[:manual] = Thread.new do
            Thread.current[:consumer] = :manual
            runner.call(row: row, observation_token: coordinator.observation_token_for(row))
          end
          name, gate = Timeout.timeout(10) { arrivals.pop }
          gates[name] = gate
          request = repository.recovery_requests(project: row.fetch("project"), slug: row.fetch("slug")).fetch(0)
          threads[:competitor] = Thread.new do
            Thread.current[:consumer] = :competitor
            dispatcher.call({}).dispatch_request(request, interactive: false)
          end
          name, gate = Timeout.timeout(10) { arrivals.pop }
          gates[name] = gate
          assert_empty launcher.launched, "both consumers must reach admission before either can launch"
          gates.fetch(winner) << true
          Timeout.timeout(10) { threads.fetch(winner).value }
          gates.fetch((threads.keys - [ winner ]).fetch(0)) << true
          results = Timeout.timeout(10) { threads.transform_values(&:value) }
          assert_equal "terminal", results.fetch(:manual).status
          assert_equal "succeeded", results.fetch(:manual).terminal_outcome
          assert_equal results.fetch(:manual).attempt_id, results.fetch(:competitor).attempt.attempt_id
          assert_equal 1, launcher.launched.size
          assert_equal 1, results.fetch(:manual).retry_count
        ensure
          gates.each_value { |pending| pending << true }
          threads.each_value { |thread| thread.kill if thread.alive?; thread.join }
        end
      end
    end
  end

  def test_status_reads_a_stranded_manual_request_without_resuming_or_repairing_it
    with_retry(limits: { max_global: 0 }) do |row, coordinator, repository, store, launcher, runner|
      deferred = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      request = repository.fetch(deferred.request_id)
      task = Hive::Task.new(row.fetch("folder"))
      current = Hive::OperationalAction.observed_row(task, project: row.fetch("project"))
      current["action_label"] = "Ready to retry"
      current.delete("recovery_observation") # Status discovers evidence independently.
      before = File.binread(task.state_file)
      payload = { "schema" => "hive-status", "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
        "ok" => true, "generated_at" => Time.now.utc.iso8601, "projects" => [ {
          "name" => row.fetch("project"), "path" => task.project_root,
          "hive_state_path" => File.dirname(File.dirname(File.dirname(task.folder))),
          "tasks" => [ current ], "legacy_stage_dirs" => [], "legacy_state_guide" => nil,
          "hidden_archived_task_count" => 0 } ] }
      status = Hive::OperationalStatus.new(status_payload: payload,
        recovery_coordinator: coordinator).to_h
      projected = status.fetch("tasks").first
      assert_equal "operator", projected.fetch("blocker_owner")
      assert_equal "operator", projected.dig("recovery", "owner")
      assert_equal "blocked", projected.dig("recovery", "status")
      assert_equal "workflow.retry", projected.dig("action", "action_id")
      assert_equal deferred.request_id, projected.dig("recovery", "request_id")
      schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-operational-status"))))
      assert schema.valid?(status), schema.validate(status).map { |error| [ error["data_pointer"], error["error"] ] }.inspect
      assert_equal before, File.binread(task.state_file)
      assert_equal request, repository.fetch(deferred.request_id)
      assert_empty store.active_attempts
      result = runner.call(row: Hive::OperationalAction.observed_row(task, project: row.fetch("project")),
        observation_token: projected.dig("action", "observation_token"))
      assert_equal "blocked", result.status
      assert_equal deferred.request_id, result.request_id
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

  def test_admission_race_returns_the_canonical_attempt_outcome
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      create = store.method(:create_launching)
      raced = false
      competitor = nil
      store.define_singleton_method(:create_launching) do |**attributes|
        unless raced
          raced = true
          request = repository.fetch(attributes.fetch(:request_id))
          competitor = dispatcher.call({}).dispatch_request(request, interactive: false)
        end
        create.call(**attributes)
      end
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "terminal", receipt.status, receipt.to_h.inspect
      assert_equal competitor.attempt.attempt_id, receipt.attempt_id
      assert_equal "succeeded", receipt.terminal_outcome
      assert_equal 1, launcher.launched.size
    end
  end

  def test_admission_race_lost_to_a_lost_attempt_fails_closed_without_relaunch
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        @launched << record
        store.mark_lost(record, reason: "fixture_owner_gone", now: Time.now.utc)
        { "claimed" => true }
      end
      create = store.method(:create_launching)
      raced = false
      store.define_singleton_method(:create_launching) do |**attributes|
        unless raced
          raced = true
          dispatcher.call({}).dispatch_request(repository.fetch(attributes.fetch(:request_id)), interactive: false)
        end
        create.call(**attributes)
      end
      receipt = runner.call(row: row, observation_token: coordinator.observation_token_for(row))
      assert_equal "unavailable", receipt.status, receipt.to_h.inspect
      assert_equal "launch_unavailable", receipt.reason
      assert_includes receipt.remediation, "Hive::Attempts::RepositoryError"
      assert_equal 1, launcher.launched.size
    end
  end

  def test_terminal_failure_interruption_before_marker_repair_remains_actionable
    with_retry do |row, coordinator, repository, store, launcher, runner, dispatcher|
      prepared = coordinator.prepare_manual(row: Hive::Recovery::API.observation(row),
        observation_token: coordinator.observation_token_for(row))
      request = repository.fetch(prepared.request_id)
      launcher.outcome = "failed"
      launch = launcher.method(:launch)
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        result = launch.call(record, claim_capability: claim_capability)
        Hive::Markers.clear_current(row.fetch("state_file"), expected_name: "error")
        result
      end
      admitted = dispatcher.call({}).dispatch_request(request, interactive: false)
      canonical = store.fetch(admitted.attempt.attempt_id)
      coordinator.mark_dispatched(request, attempt_id: canonical.attempt_id,
        terminal: true, outcome: canonical.outcome, now: Time.iso8601(canonical.receipt.fetch("ended_at")))
      current = Hive::OperationalAction.observed_row(Hive::Task.new(row.fetch("folder")), project: row.fetch("project"))
      assert current["recovery_observation"], current.inspect
      receipt = runner.call(row: current, observation_token: coordinator.observation_token_for(current))
      assert_equal "terminal", receipt.status
      assert_equal "failed", receipt.terminal_outcome
      assert_equal "recovery_attempt_failed", Hive::Markers.current(row.fetch("state_file")).attrs["reason"]
      assert_equal 1, receipt.retry_count
      assert_equal 1, launcher.launched.size
    end
  end

  private

  def with_retry(stage: "6-review", marker: "REVIEW_ERROR", reason: "review_orphaned", limits: {}, workflow: "coding", policy: nil)
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
            task_resolver: ->(_) { task },
            routing_policy_resolver: policy && ->(*) { policy }, limits: { max_global: 5, max_per_project: 5, max_daily: 50 }.merge(settings))
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
