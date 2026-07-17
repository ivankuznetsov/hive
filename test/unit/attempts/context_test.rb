require "test_helper"
require "hive/attempts/context"
require "hive/lock"
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

    with_attempt_context(attempt_id: "attempt-1", task_generation: "generation-1") do
      assert Hive::Attempts::Context.active?
      assert_equal(
        { "attempt_id" => "attempt-1", "task_generation" => "generation-1" },
        Hive::Attempts::Context.projection
      )
    end

    refute Hive::Attempts::Context.active?
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

          assert_equal "generation-env", context.task_generation
          assert_equal "task", context.task_slug
          assert_equal "4-execute", context.intended_stage
          assert_empty ENV.keys.grep(/\AHIVE_ATTEMPT_/)
        end
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

  private

  def with_running_attempt
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      record = store.create_launching(
        attempt_id: "attempt-env", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
        task_generation: "generation-env", progress_token: "progress", provider: "codex",
        worker_argv: WORKER_ARGV,
        claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
        starting_revision: nil, retry_charge: 0, inherited_outputs: [],
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
