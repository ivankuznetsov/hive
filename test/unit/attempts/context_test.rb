require "test_helper"
require "hive/attempts/context"
require "hive/attempts/generation"
require "hive/lock"
require "hive/patrol_fix/attempt_diagnostic"
require "hive/task_resolver"

class AttemptsContextTest < Minitest::Test
  include HiveTestHelper

  CLAIM_CAPABILITY = "c" * 64
  WORKER_ARGV = [ "hive", "run", "/project/.hive-state/stages/4-execute/task" ].freeze
  FakeTask = Struct.new(:id, :slug, :stage_index, :stage_name, keyword_init: true)

  def teardown
    Hive::Attempts::Context.reset!
    super
  end

  def test_test_context_projects_attempt_identity_without_a_production_bypass
    assert_raises(NoMethodError) do
      Hive::Attempts::Context.with(attempt_id: "forged", task_generation: "forged") { nil }
    end
    assert_raises(NoMethodError) do
      Hive::Attempts::Context.new(attempt_id: "forged", task_generation: "forged")
    end

    with_attempt_context(
      attempt_id: "attempt-1", task_generation: 7, ownership_generation: "generation-1"
    ) do
      assert Hive::Attempts::Context.active?
      assert_equal(
        {
          "attempt_id" => "attempt-1", "task_generation" => "generation-1",
          "ownership_generation" => "generation-1", "task_input_epoch" => 7
        },
        Hive::Attempts::Context.projection
      )
    end

    refute Hive::Attempts::Context.active?
  end

  def test_explicit_context_exposes_only_the_persisted_admitted_route
    routing = explicit_routing
    context = Hive::Attempts::Context.send(
      :new,
      attempt_id: "attempt-1",
      task_generation: 7,
      ownership_generation: "generation-1",
      routing: routing
    )
    routing.fetch("route")["model"] = "changed-after-admission"

    assert context.explicit_routing?
    assert_equal "decision-1", context.routing_decision.fetch("decision_id")
    assert_equal "codex-account-a", context.provider_account_id
    assert_equal "codex", context.adapter
    assert_equal "codex-home-a", context.launch_binding_id
    assert_equal "gpt-5.6-sol", context.model
    assert_equal "high", context.effort
    assert_equal 2, context.circuit_generations.length
    assert_equal 1, context.probe_bindings.length
    assert_raises(FrozenError) { context.admitted_route["model"].replace("other") }

    legacy = Hive::Attempts::Context.send(
      :new, attempt_id: "legacy", task_generation: 0
    )
    refute legacy.explicit_routing?
    assert_nil legacy.admitted_route
    assert_empty legacy.circuit_generations
    assert legacy.circuit_generations.frozen?
  end

  def test_environment_context_is_authenticated_bound_and_scrubbed
    with_running_attempt do |store, _record|
      resolver = Struct.new(:task) { def resolve = task }.new(
        FakeTask.new(id: 42, slug: "task", stage_index: 4, stage_name: "execute")
      )
      test_case = self
      with_replaced_singleton_method(Hive::TaskResolver, :new, lambda { |*_args, **_kwargs|
        test_case.assert_empty ENV.keys.grep(/\AHIVE_ATTEMPT_/)
        resolver
      }) do
        with_context_environment(store, capability: CLAIM_CAPABILITY) do
          context = Hive::Attempts::Context.install_from_env!(argv: WORKER_ARGV)

          assert_equal 5, context.task_generation
          assert_equal "generation-env", context.ownership_generation
          assert_equal "demo", context.project
          assert_equal "task", context.task_slug
          assert_equal "4-execute", context.intended_stage
          assert_empty ENV.keys.grep(/\AHIVE_ATTEMPT_/)
        end
      end
    end
  end

  def test_environment_context_publishes_opaque_ownership_generation
    with_running_attempt do |store, _record|
      resolver = Struct.new(:task) { def resolve = task }.new(
        FakeTask.new(id: 42, slug: "task", stage_index: 4, stage_name: "execute")
      )
      diagnostic_reader, diagnostic_writer = IO.pipe
      with_replaced_singleton_method(
        Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }
      ) do
        with_env("HIVE_ATTEMPT_DIAGNOSTIC_FD" => diagnostic_writer.fileno.to_s) do
          with_context_environment(store, capability: CLAIM_CAPABILITY) do
            context = Hive::Attempts::Context.install_from_env!(argv: WORKER_ARGV)
            installed_writer = context.instance_variable_get(:@diagnostic_writer)
            assert installed_writer.instance_variable_get(:@io).close_on_exec?
            draft = Hive::PatrolFix::AttemptDiagnostic.normalize(
              { "status" => "error", "exit_code" => 7 },
              stage: context.intended_stage,
              task_generation: context.ownership_generation,
              attempt_id: context.attempt_id,
              recorded_at: Time.now.utc
            )
            assert context.publish_attempt_diagnostic(draft)
            frame = Hive::Attempts::DiagnosticChannel.read(diagnostic_reader)
            assert_equal "valid", frame.status
            assert_equal "generation-env", frame.document.fetch("task_generation")
            refute_equal context.task_generation.to_s, frame.document.fetch("task_generation")
          end
        end
      end
    ensure
      [ diagnostic_reader, diagnostic_writer ].compact.each do |io|
        io.close unless io.closed?
      rescue Errno::EBADF
        nil
      end
    end
  end

  def test_explicit_environment_context_installs_the_dedicated_evidence_writer
    routing = explicit_routing
    routing["probe_bindings"] = []
    with_running_attempt(routing: routing) do |store, _record|
      resolver = Struct.new(:task) { def resolve = task }.new(
        FakeTask.new(id: 42, slug: "task", stage_index: 4, stage_name: "execute")
      )
      evidence_reader, evidence_writer = IO.pipe
      with_replaced_singleton_method(
        Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }
      ) do
        with_env("HIVE_ATTEMPT_EVIDENCE_FD" => evidence_writer.fileno.to_s) do
          with_context_environment(store, capability: CLAIM_CAPABILITY) do
            context = Hive::Attempts::Context.install_from_env!(argv: WORKER_ARGV)
            signal = {
              "failure_class" => "model_capacity",
              "scope" => {
                "kind" => "model", "provider_account_id" => "codex-account-a",
                "model" => "gpt-5.6-sol"
              },
              "provenance" => "codex_jsonl_transport",
              "reset_hint_seconds" => 30
            }
            assert context.publish_provider_signal(signal)
            assert_equal signal, Hive::Attempts::EvidenceChannel.read(
              evidence_reader, route: routing.fetch("route")
            )
          end
        end
      end
    ensure
      [ evidence_reader, evidence_writer ].compact.each do |io|
        io.close unless io.closed?
      rescue Errno::EBADF
        nil
      end
    end
  end

  def test_forged_capability_and_cross_task_binding_fail_closed
    with_running_attempt do |store, _record|
      resolver = Struct.new(:task) { def resolve = task }.new(
        FakeTask.new(id: 99, slug: "other-task", stage_index: 4, stage_name: "execute")
      )
      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }) do
        with_context_environment(store, capability: "f" * 64) do
          error = assert_raises(Hive::Attempts::StoreError) do
            Hive::Attempts::Context.install_from_env!(argv: WORKER_ARGV)
          end
          assert_includes error.message, "capability"
        end

        with_context_environment(store, capability: CLAIM_CAPABILITY) do
          error = assert_raises(Hive::Attempts::StoreError) do
            Hive::Attempts::Context.install_from_env!(argv: WORKER_ARGV)
          end
          assert_includes error.message, "task or intended stage"
        end
      end
      refute Hive::Attempts::Context.active?
    end
  end

  def test_wrong_argv_and_unreleased_gate_fail_closed
    with_running_attempt do |store, _record|
      with_context_environment(store, capability: CLAIM_CAPABILITY) do
        error = assert_raises(Hive::Attempts::StoreError) do
          Hive::Attempts::Context.install_from_env!(argv: [ "hive", "run", "other" ])
        end
        assert_includes error.message, "argv"
      end

      with_context_environment(store, capability: CLAIM_CAPABILITY, gate: "") do
        error = assert_raises(Hive::Attempts::StoreError) do
          Hive::Attempts::Context.install_from_env!(argv: WORKER_ARGV)
        end
        assert_includes error.message, "gate"
      end
    end
  end

  def test_replacement_process_identity_cannot_install_context
    with_running_attempt do |store, record|
      store.checkpoint(
        record, checkpoint: record.checkpoint,
        worker: record.worker.merge("pid" => Process.pid + 100_000),
        now: Time.now.utc
      )

      with_context_environment(store, capability: CLAIM_CAPABILITY) do
        error = assert_raises(Hive::Attempts::StoreError) do
          Hive::Attempts::Context.install_from_env!(argv: WORKER_ARGV)
        end
        assert_includes error.message, "process identity"
      end
    end
  end

  def test_generation_is_revalidated_once_before_worker_side_effects
    task = FakeTask.new(id: 42, slug: "task", stage_index: 4, stage_name: "execute")
    current = Struct.new(:task_generation, :ownership_generation, :task_input_epoch).new(
      "generation-current", "generation-current", 0
    )
    calls = 0
    test_case = self
    resolver = lambda do |task:, project:, intended_stage:|
      calls += 1
      test_case.assert_equal "demo", project
      test_case.assert_equal "4-execute", intended_stage
      current
    end
    context = Hive::Attempts::Context.send(
      :new, attempt_id: "attempt-1", task_generation: "generation-current",
      project: "demo", intended_stage: "4-execute"
    )

    with_replaced_singleton_method(Hive::Attempts::Generation, :resolve, resolver) do
      assert context.validate_generation!(task)
      assert context.validate_generation!(task)
    end
    assert_equal 1, calls

    stale = Hive::Attempts::Context.send(
      :new, attempt_id: "attempt-stale", task_generation: "generation-old",
      project: "demo", intended_stage: "4-execute"
    )
    with_replaced_singleton_method(Hive::Attempts::Generation, :resolve, resolver) do
      error = assert_raises(Hive::ConcurrentRunError) { stale.validate_generation!(task) }
      assert_includes error.message, "generation is stale"
      assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
    end

    epoch_stale = Hive::Attempts::Context.send(
      :new, attempt_id: "attempt-epoch-stale", task_generation: 1,
      ownership_generation: "generation-current", project: "demo", intended_stage: "4-execute"
    )
    current_epoch = Struct.new(:ownership_generation, :task_input_epoch).new(
      "generation-current", 2
    )
    with_replaced_singleton_method(Hive::Attempts::Generation, :resolve, ->(**) { current_epoch }) do
      assert_raises(Hive::ConcurrentRunError) { epoch_stale.validate_generation!(task) }
    end

    successor = Hive::Attempts::Context.send(
      :new,
      attempt_id: "attempt-successor",
      task_generation: 2,
      ownership_generation: "generation-predecessor",
      project: "demo",
      intended_stage: "4-execute",
      progress_token: "post-clear-progress",
      predecessor_attempt_id: "attempt-predecessor"
    )
    current_successor = Struct.new(
      :ownership_generation, :task_input_epoch, :progress_token
    ).new("generation-after-marker-clear", 2, "post-clear-progress")
    with_replaced_singleton_method(
      Hive::Attempts::Generation, :resolve, ->(**) { current_successor }
    ) do
      assert successor.validate_generation!(task)
    end

    stale_successor = Hive::Attempts::Context.send(
      :new,
      attempt_id: "attempt-successor-stale",
      task_generation: 2,
      ownership_generation: "generation-predecessor",
      project: "demo",
      intended_stage: "4-execute",
      progress_token: "admitted-progress",
      predecessor_attempt_id: "attempt-predecessor"
    )
    with_replaced_singleton_method(
      Hive::Attempts::Generation, :resolve, ->(**) { current_successor }
    ) do
      assert_raises(Hive::ConcurrentRunError) do
        stale_successor.validate_generation!(task)
      end
    end
  end

  def test_workflow_task_binding_and_invalid_inherited_descriptor_are_checked
    task = FakeTask.new(id: 42, slug: "task", stage_index: 2, stage_name: "brainstorm")
    resolver = Struct.new(:task) { def resolve = task }.new(task)
    record = {
      "project" => "demo", "task_id" => "42", "task_slug" => "task",
      "intended_stage" => "3-plan"
    }

    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }) do
      assert_nil Hive::Attempts::Context.send(
        :validate_task_binding!, record, [ "hive", "plan", "task" ]
      )
    end

    assert_raises(Hive::Attempts::StoreError) do
      Hive::Attempts::Context.send(:read_inherited, "not-an-fd", limit: 1)
    end
  end

  def test_generic_approve_binds_to_the_tasks_current_stage
    task = FakeTask.new(id: 42, slug: "task", stage_index: 1, stage_name: "inbox")
    resolver = Struct.new(:task) { def resolve = task }.new(task)
    record = {
      "project" => "demo", "task_id" => "42", "task_slug" => "task",
      "intended_stage" => "1-inbox"
    }

    with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }) do
      assert_nil Hive::Attempts::Context.send(
        :validate_task_binding!, record, [ "hive", "approve", "task", "--from", "1-inbox" ]
      )
    end
  end

  def test_evidence_rework_binds_its_nested_task_target_to_artifacts
    task = FakeTask.new(id: 42, slug: "task", stage_index: 7, stage_name: "artifacts")
    resolver = Struct.new(:task) { def resolve = task }.new(task)
    record = {
      "project" => "demo", "task_id" => "42", "task_slug" => "task",
      "intended_stage" => "7-artifacts"
    }
    argv = [
      "hive", "evidence", "rework", "task", "--stage", "7-artifacts",
      "--generation", "a" * 64, "--recovery-digest", "b" * 64
    ]
    test_case = self

    with_replaced_singleton_method(Hive::TaskResolver, :new, lambda { |target, **options|
      test_case.assert_equal "task", target
      test_case.assert_equal({ project_filter: "demo" }, options)
      resolver
    }) do
      assert_nil Hive::Attempts::Context.send(:validate_task_binding!, record, argv)
    end
  end

  def test_module_hook_binding_uses_its_authenticated_subject_without_task_resolution
    subject = {
      "kind" => "module_hook", "project_id" => "project-1", "module" => "patrol",
      "hook" => "scheduled-scan", "event_id" => "event-1", "occurrence_id" => "event-1",
      "event_name" => "schedule.tick", "module_generation" => "a" * 40,
      "configuration_digest" => "b" * 64, "grant_digest" => "c" * 64
    }
    argv = [
      "hive", "__module-hook", "patrol", "scheduled-scan",
      "--project", "demo", "--event-id", "event-1"
    ]
    record = Hive::Attempts::Record.launching(
      attempt_id: "attempt-module", request_id: "request-module",
      predecessor_attempt_id: nil, task_id: nil, project: "demo",
      task_slug: "module-patrol-scheduled-scan", intended_stage: "module-hook",
      task_generation: "generation-module", progress_token: "event-1",
      provider: "native", worker_argv: argv,
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      subject: subject, launch_timeout_sec: 30, now: Time.now.utc
    )

    assert_nil Hive::Attempts::Context.send(:validate_task_binding!, record, argv)
    assert_raises(Hive::Attempts::StoreError) do
      Hive::Attempts::Context.send(
        :validate_task_binding!, record, argv.take(6) + [ "other-event" ]
      )
    end

    incomplete = Struct.new(:subject) do
      def [](key)
        {
          "project" => "demo", "task_id" => nil,
          "intended_stage" => "module-hook"
        }[key]
      end
    end.new(subject.except("event_id"))
    error = assert_raises(Hive::Attempts::StoreError) do
      Hive::Attempts::Context.send(
        :validate_module_hook_binding!, incomplete, argv
      )
    end
    assert_includes error.message, "binding is incomplete"
  end

  def test_legacy_opaque_generation_is_bridged_without_becoming_an_epoch
    context = Hive::Attempts::Context.send(
      :new, attempt_id: "attempt", task_generation: "opaque"
    )

    assert_equal 0, context.task_generation
    assert_equal "opaque", context.ownership_generation
    assert_raises(ArgumentError) do
      Hive::Attempts::Context.send(:new, attempt_id: "attempt", task_generation: -1)
    end

    unreadable = Object.new
    unreadable.define_singleton_method(:to_s) { raise TypeError, "not stringable" }
    error = assert_raises(ArgumentError) do
      Hive::Attempts::Context.send(:new, attempt_id: "attempt", task_generation: unreadable)
    end
    assert_includes error.message, "numeric task generation"
  end

  private

  def explicit_routing
    account_scope = {
      "kind" => "provider_account", "provider_account_id" => "codex-account-a", "model" => nil
    }
    model_scope = {
      "kind" => "model", "provider_account_id" => "codex-account-a", "model" => "gpt-5.6-sol"
    }
    {
      "mode" => "explicit",
      "policy_digest" => "a" * 64,
      "decision" => {
        "decision_id" => "decision-1", "policy_digest" => "a" * 64,
        "decided_at" => Time.utc(2026, 8, 10, 12).iso8601(6), "exclusions" => []
      },
      "route" => {
        "route_id" => "codex-account-a/gpt-5.6-sol",
        "provider_account_id" => "codex-account-a", "adapter" => "codex",
        "launch_binding_id" => "codex-home-a", "model" => "gpt-5.6-sol", "effort" => "high"
      },
      "circuit_generations" => [
        { "scope" => account_scope, "journal_epoch" => 1, "observed_generation" => 4 },
        { "scope" => model_scope, "journal_epoch" => 1, "observed_generation" => 7 }
      ],
      "probe_bindings" => [
        {
          "scope" => model_scope, "journal_epoch" => 1,
          "observed_generation" => 7, "claim_generation" => 8,
          "attempt_id" => "attempt-1", "task_generation" => "generation-1",
          "ownership_fence" => "generation-1"
        }
      ]
    }
  end

  def with_running_attempt(routing: { "mode" => "legacy" })
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      record = store.create_launching(
        attempt_id: "attempt-env", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
        task_generation: "generation-env", task_input_epoch: 5,
        progress_token: "progress", provider: "codex",
        worker_argv: WORKER_ARGV,
        claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
        starting_revision: nil, retry_charge: 0, inherited_outputs: [], routing: routing,
        launch_timeout_sec: 30, now: Time.now.utc
      )
      identity = {
        "pid" => Process.pid,
        "start_fingerprint" => Hive::Lock.process_start_time(Process.pid),
        "session_id" => Process.getsid(Process.pid),
        "process_group_id" => Process.getpgid(Process.pid)
      }
      claimed = store.claim(
        record, owner: identity, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: Time.now.utc
      )
      running = store.first_heartbeat(claimed, stale_sec: 30, now: Time.now.utc)
      running = store.checkpoint(
        running, checkpoint: running.checkpoint, worker: identity, now: Time.now.utc
      )
      yield store, running
    end
  end

  def with_context_environment(store, capability:, gate: "1")
    context_r, context_w = IO.pipe
    gate_r, gate_w = IO.pipe
    context_w.write(capability)
    context_w.close
    gate_w.write(gate) unless gate.empty?
    gate_w.close
    test_case = self
    with_replaced_singleton_method(Hive::Attempts::Store, :new, lambda { |**options|
      test_case.assert_empty options, "worker context must not accept an environment-selected store root"
      store
    }) do
      with_env(
        "HIVE_ATTEMPT_INTERNAL" => "1",
        "HIVE_ATTEMPT_ID" => "attempt-env",
        "HIVE_ATTEMPT_STORE_ROOT" => "/attacker-controlled/store",
        "HIVE_ATTEMPT_CONTEXT_FD" => context_r.fileno.to_s,
        "HIVE_ATTEMPT_GATE_FD" => gate_r.fileno.to_s
      ) { yield }
    end
  ensure
    [ context_r, context_w, gate_r, gate_w ].compact.each do |io|
      io.close unless io.closed?
    rescue Errno::EBADF
      nil
    end
  end
end
