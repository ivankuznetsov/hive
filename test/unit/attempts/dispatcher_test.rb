require "test_helper"
require "hive/attempts/dispatcher"

class AttemptsDispatcherTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64
  FakeTask = Struct.new(
    :id, :slug, :state_file, :stage_index, :stage_name, :project_root, :worktree_path,
    :workflow, keyword_init: true
  )
  FakeRequest = Struct.new(
    :slug, :project, :argv, :request_id, :task_generation,
    :predecessor_attempt_id, :inherited_outputs,
    keyword_init: true
  )

  class FakeLauncher
    attr_reader :launched

    def initialize(result: { "claimed" => true }, error: nil)
      @launched = []
      @result = result
      @error = error
    end

    def preflight! = true

    def launch(record, claim_capability:)
      @launched << [ record, claim_capability ]
      raise @error if @error

      @result
    end
  end

  def test_same_and_different_request_ids_share_one_live_generation
    with_dispatcher do |dispatcher, launcher, task|
      first = dispatch(dispatcher, task, request_id: "request-one", interactive: true)
      same = dispatch(dispatcher, task, request_id: "request-one", interactive: true)
      different = dispatch(dispatcher, task, request_id: "request-two", interactive: false)

      assert_equal :accepted, first.status
      assert_equal :existing_live, same.status
      assert_equal :existing_live, different.status
      assert_equal first.attempt.attempt_id, same.attempt.attempt_id
      assert_equal first.attempt.attempt_id, different.attempt.attempt_id
      assert_equal({ "attempt_id" => first.attempt.attempt_id }, same.attach_descriptor)
      assert_nil different.attach_descriptor
      assert_equal 1, launcher.launched.size
      assert_equal [ "hive", "run", task.slug ], first.attempt["worker_argv"]
      capability = launcher.launched.first.last
      assert Hive::Attempts::Capability.matches?(first.attempt["claim_capability_digest"], capability)
      refute_includes first.attempt.to_h.values, capability
    end
  end

  def test_terminal_duplicate_replays_receipt_without_launch_or_daily_charge
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      owner = { "pid" => Process.pid, "start_fingerprint" => "start",
                "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
      capability = launcher.launched.first.last
      claimed = store.claim(
        first.attempt, owner: owner, claim_capability: capability,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      terminal = store.terminalize(
        running, outcome: "succeeded", exit_status: 0,
        final_checkpoint: { "revision" => "b" * 40, "progress_token" => first.attempt["progress_token"] },
        output_references: [],
        log_reference: { "path" => "logs/log.frames", "size" => 0, "sha256" => "0" * 64 },
        now: NOW + 3
      )

      replay = dispatch(dispatcher, task, request_id: "other-request")
      assert_equal :terminal_replay, replay.status
      assert_equal terminal.receipt, replay.receipt
      assert_equal 1, launcher.launched.size
      assert_equal 1, Hive::Attempts::CapacitySnapshot.build(store: store, now: NOW + 4)
                                                    .daily_count("demo", NOW.to_date)
    end
  end

  def test_failed_terminal_replays_same_request_but_new_request_retries
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      failed = terminalize_attempt(
        store, launcher, first, outcome: "failed", exit_status: 1, now: NOW + 3
      )

      replay = dispatch(dispatcher, task, request_id: "request-one")
      retry_result = dispatch(dispatcher, task, request_id: "request-two")

      assert_equal :terminal_replay, replay.status
      assert_equal failed.receipt, replay.receipt
      assert_equal :accepted, retry_result.status
      refute_equal first.attempt.attempt_id, retry_result.attempt.attempt_id
      assert_equal 2, launcher.launched.size
    end
  end

  def test_successful_retry_replays_for_new_requests_without_changing_old_request_result
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      failed = terminalize_attempt(
        store, launcher, first, outcome: "failed", exit_status: 1, now: NOW + 3
      )
      retry_result = dispatch(dispatcher, task, request_id: "request-two")
      succeeded = terminalize_attempt(
        store, launcher, retry_result, outcome: "succeeded", exit_status: 0, now: NOW + 6
      )

      old_request = dispatch(dispatcher, task, request_id: "request-one")
      new_request = dispatch(dispatcher, task, request_id: "request-three")

      assert_equal failed.receipt, old_request.receipt
      assert_equal succeeded.receipt, new_request.receipt
      assert_equal :terminal_replay, new_request.status
      assert_equal 2, launcher.launched.size
    end
  end

  def test_successful_brainstorm_receipt_without_artifact_allows_one_new_repair_request
    with_dispatcher do |dispatcher, launcher, task, store|
      task.stage_index = 2
      task.stage_name = "brainstorm"
      task.state_file = File.join(File.dirname(task.state_file), "brainstorm.md")
      File.write(task.state_file, "")

      first = dispatch(
        dispatcher, task, request_id: "request-one",
        intended_stage: "2-brainstorm"
      )
      stale_success = terminalize_attempt(
        store, launcher, first, outcome: "succeeded", exit_status: 0, now: NOW + 3
      )

      repair = dispatch(
        dispatcher, task, request_id: "request-one",
        intended_stage: "2-brainstorm"
      )
      duplicate = dispatch(
        dispatcher, task, request_id: "request-two",
        intended_stage: "2-brainstorm"
      )

      assert_equal :accepted, repair.status
      assert_equal :existing_live, duplicate.status
      assert_equal repair.attempt.attempt_id, duplicate.attempt.attempt_id
      refute_equal stale_success.attempt_id, repair.attempt.attempt_id
      assert_equal 2, launcher.launched.size

      File.write(
        task.state_file,
        "## Round 1\n### Q1. Scope?\n### A1.\n<!-- WAITING -->\n"
      )
      repaired = terminalize_attempt(
        store, launcher, repair, outcome: "succeeded", exit_status: 0, now: NOW + 6
      )
      later = dispatch(
        dispatcher, task, request_id: "request-one",
        intended_stage: "2-brainstorm",
        generation: repair.attempt.task_generation
      )

      assert_equal :terminal_replay, later.status
      assert_equal repaired.receipt, later.receipt
      assert_equal 2, launcher.launched.size
    end
  end

  def test_failed_brainstorm_artifact_repair_allows_a_new_request
    with_dispatcher do |dispatcher, launcher, task, store|
      task.stage_index = 2
      task.stage_name = "brainstorm"
      task.state_file = File.join(File.dirname(task.state_file), "brainstorm.md")
      File.write(task.state_file, "")

      stale = dispatch(
        dispatcher, task, request_id: "request-one",
        intended_stage: "2-brainstorm"
      )
      terminalize_attempt(
        store, launcher, stale, outcome: "succeeded", exit_status: 0, now: NOW + 3
      )
      repair = dispatch(
        dispatcher, task, request_id: "request-two",
        intended_stage: "2-brainstorm"
      )
      failed = terminalize_attempt(
        store, launcher, repair, outcome: "failed", exit_status: 1, now: NOW + 6
      )

      replay = dispatch(
        dispatcher, task, request_id: "request-three",
        intended_stage: "2-brainstorm",
        generation: repair.attempt.task_generation
      )

      assert_equal :accepted, replay.status
      refute_equal failed.attempt_id, replay.attempt.attempt_id
      assert_equal 3, launcher.launched.size
    end
  end

  def test_non_coding_stage_named_brainstorm_has_no_coding_artifact_contract
    with_dispatcher do |dispatcher, launcher, task, store|
      task.workflow = "writing"
      task.stage_index = 2
      task.stage_name = "brainstorm"
      File.write(task.state_file, "")
      first = dispatch(
        dispatcher, task, request_id: "writing-one",
        intended_stage: "2-brainstorm"
      )
      terminal = terminalize_attempt(
        store, launcher, first, outcome: "succeeded", exit_status: 0, now: NOW + 3
      )

      replay = dispatch(
        dispatcher, task, request_id: "writing-two",
        intended_stage: "2-brainstorm"
      )

      assert_equal :terminal_replay, replay.status
      assert_equal terminal.receipt, replay.receipt
      assert_equal 1, launcher.launched.size
    end
  end

  def test_failed_successor_allows_retry_after_resolved_lost_ancestor
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)
      successor = dispatcher.dispatch_successor(
        predecessor: lost, task: task, project: "demo",
        argv: [ "hive", "run", task.slug ], request_id: "request-two",
        provider: "codex", retry_charge: 1, now: NOW + 2
      )
      terminalize_attempt(
        store, launcher, successor, outcome: "failed", exit_status: 1, now: NOW + 5
      )

      retry_result = dispatch(dispatcher, task, request_id: "request-three")

      assert_equal :accepted, retry_result.status
      assert_equal "attempt-three", retry_result.attempt.attempt_id
      assert_equal 3, launcher.launched.size
    end
  end

  def test_capacity_defers_before_creating_an_attempt
    with_dispatcher(limits: { max_global: 0, max_per_project: 1, max_daily: 10 }) do |dispatcher, launcher, task, store|
      result = dispatch(dispatcher, task, request_id: "request-one")

      assert_equal :deferred, result.status
      assert_equal "capacity", result.reason
      assert_empty launcher.launched
      assert_empty store.scan.records
    end
  end

  def test_distinct_generations_share_one_multiprocess_capacity_transaction
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    with_tmp_dir do |root|
      attempt_root = File.join(root, "attempts")
      tasks = 2.times.map do |index|
        state_file = File.join(root, "task-#{index}.md")
        File.write(state_file, "task #{index}\n<!-- WAITING -->\n")
        FakeTask.new(
          id: 100 + index, slug: "durable-task-#{index}", state_file: state_file,
          stage_index: 4, stage_name: "execute"
        )
      end
      children = []

      spawn_dispatch = lambda do |task, index|
        entered_r, entered_w = IO.pipe
        release_r, release_w = IO.pipe
        result_r, result_w = IO.pipe
        pid = fork do
          entered_r.close
          release_w.close
          result_r.close
          store = Hive::Attempts::Store.new(root: attempt_root)
          original_generation_lock = store.method(:with_generation_lock)
          store.define_singleton_method(:with_generation_lock) do |generation, &block|
            original_generation_lock.call(generation) do
              entered_w.write("1")
              entered_w.close
              release_r.read(1)
              block.call
            end
          end
          dispatcher = Hive::Attempts::Dispatcher.new(
            store: store, launcher: FakeLauncher.new,
            limits: { max_global: 1, max_per_project: 1, max_daily: 50 },
            clock: -> { NOW }, id_generator: -> { "attempt-#{index}" },
            capability_generator: -> { CLAIM_CAPABILITY }
          )
          result = dispatch(dispatcher, task, request_id: "request-#{index}")
          Marshal.dump([ result.status, result.reason ], result_w)
        rescue StandardError => e
          Marshal.dump([ :error, e.class.name, e.message, e.backtrace ], result_w)
        ensure
          [ entered_w, release_r, result_w ].each do |io|
            io.close unless io.closed?
          rescue IOError
            nil
          end
          exit! 0
        end
        entered_w.close
        release_r.close
        result_w.close
        child = { pid: pid, entered: entered_r, release: release_w, result: result_r }
        children << child
        child
      end

      first = spawn_dispatch.call(tasks.fetch(0), 0)
      assert_equal "1", first.fetch(:entered).read(1)
      second = spawn_dispatch.call(tasks.fetch(1), 1)
      assert_nil IO.select([ second.fetch(:entered) ], nil, nil, 0.2),
                 "second generation entered while the first held admission"

      first.fetch(:release).write("1")
      first.fetch(:release).close
      first_result = Marshal.load(first.fetch(:result))
      Process.wait(first.fetch(:pid))

      assert_equal "1", second.fetch(:entered).read(1)
      second.fetch(:release).write("1")
      second.fetch(:release).close
      second_result = Marshal.load(second.fetch(:result))
      Process.wait(second.fetch(:pid))

      assert_equal [ :accepted, nil ], first_result
      assert_equal [ :deferred, "capacity" ], second_result
      assert_equal 1, Hive::Attempts::Store.new(root: attempt_root).scan.records.length
      children.clear
    ensure
      children.each do |child|
        Process.kill("TERM", child.fetch(:pid))
        Process.wait(child.fetch(:pid))
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def test_failed_launcher_handoff_marks_reservation_lost_and_defers
    with_dispatcher do |dispatcher, launcher, task, store|
      launcher.instance_variable_set(:@result, { "claimed" => false, "error" => "wrapper unavailable" })

      result = dispatch(dispatcher, task, request_id: "request-one", interactive: true)

      assert_equal :deferred, result.status
      assert_equal "launch_handoff_failed", result.reason
      assert_nil result.attach_descriptor
      lost = store.fetch(result.attempt.attempt_id)
      assert_equal "lost", lost.state
      assert_equal "launch_handoff_failed", lost["loss"].fetch("reason")
      assert_equal "wrapper unavailable", lost["diagnostics"].fetch("launch_handoff_error")
    end
  end

  def test_launching_handoff_timeout_keeps_the_accepted_reservation_live
    with_dispatcher do |dispatcher, launcher, task, store|
      launcher.instance_variable_set(
        :@result, { "claimed" => false, "state" => "launching", "attempt_id" => "attempt-one" }
      )

      result = dispatch(dispatcher, task, request_id: "request-one", interactive: true)

      assert_equal :accepted, result.status
      assert_equal "launching", store.fetch(result.attempt.attempt_id).state
      assert_equal({ "attempt_id" => result.attempt.attempt_id }, result.attach_descriptor)
    end
  end

  def test_launcher_exception_marks_reservation_lost_and_defers
    with_dispatcher do |dispatcher, launcher, task, store|
      launcher.instance_variable_set(:@error, Errno::EIO.new("handoff pipe failed"))

      result = dispatch(dispatcher, task, request_id: "request-one")

      assert_equal :deferred, result.status
      lost = store.fetch(result.attempt.attempt_id)
      assert_equal "lost", lost.state
      assert_includes lost["diagnostics"].fetch("launch_handoff_error"), "handoff pipe failed"
    end
  end

  def test_false_handoff_adopts_a_wrapper_that_claimed_before_cleanup
    with_dispatcher do |dispatcher, launcher, task, store|
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        @launched << [ record, claim_capability ]
        owner = {
          "pid" => Process.pid, "start_fingerprint" => "wrapper-start",
          "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
        }
        store.claim(
          record, owner: owner, claim_capability: claim_capability,
          first_heartbeat_timeout_sec: 30, now: NOW + 1
        )
        { "claimed" => false }
      end

      result = dispatch(dispatcher, task, request_id: "request-one", interactive: true)

      assert_equal :accepted, result.status
      assert result.attempt.claimed?
      assert_equal({ "attempt_id" => result.attempt.attempt_id }, result.attach_descriptor)
    end
  end

  def test_failed_handoff_cas_race_adopts_a_terminal_attempt
    with_dispatcher do |dispatcher, launcher, task, store|
      created = dispatch(dispatcher, task, request_id: "request-one").attempt
      owner = {
        "pid" => Process.pid, "start_fingerprint" => "start",
        "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
      }
      claimed = store.claim(
        created, owner: owner, claim_capability: launcher.launched.first.last,
        first_heartbeat_timeout_sec: 30, now: NOW + 1
      )
      running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
      terminal = store.terminalize(
        running, outcome: "failed", exit_status: 7,
        final_checkpoint: running.checkpoint, output_references: [],
        log_reference: { "path" => "logs/log.frames", "size" => 0, "sha256" => "0" * 64 },
        now: NOW + 3
      )
      fetches = [ created, terminal ]
      racing_store = Object.new
      racing_store.define_singleton_method(:fetch) { |_attempt_id| fetches.shift }
      racing_store.define_singleton_method(:mark_lost) do |*_args, **_kwargs|
        raise Hive::Attempts::CompareAndSwapFailed, "terminalized"
      end
      dispatcher.instance_variable_set(:@store, racing_store)

      result = dispatcher.send(:resolve_failed_handoff, created, interactive: true)

      assert_equal :terminal_replay, result.status
      assert_equal terminal.receipt, result.receipt
      assert_equal({ "attempt_id" => terminal.attempt_id }, result.attach_descriptor)
    end
  end

  def test_successor_inherits_generation_predecessor_outputs_and_retry_charge
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)
      capture = { "path" => "outputs/capture.json", "size" => 2, "sha256" => "1" * 64 }
      lost = store.fetch(lost.attempt_id).with(
        "current_outputs" => [ capture ],
        "retry_charge" => 2
      )
      # Persist the fixture through the store's guarded checkpoint equivalent
      # is impossible after loss, so pass the durable predecessor plus explicit
      # inherited outputs/retry charge as the healer will in U6.
      successor = dispatcher.dispatch_successor(
        predecessor: lost, task: task, project: "demo", argv: [ "hive", "run", task.slug ],
        request_id: "request-two", provider: "codex", inherited_outputs: [ capture ],
        retry_charge: 2, now: NOW + 2
      )

      assert_equal :accepted, successor.status
      refute_equal lost.attempt_id, successor.attempt.attempt_id
      assert_equal lost.task_generation, successor.attempt.task_generation
      assert_equal lost.attempt_id, successor.attempt["predecessor_attempt_id"]
      assert_equal [ capture ], successor.attempt["inherited_outputs"]
      assert_equal 2, successor.attempt["retry_charge"]
      assert_equal 2, launcher.launched.size
    end
  end

  def test_empty_successor_outputs_fall_back_to_all_predecessor_outputs
    with_dispatcher do |dispatcher, _launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      inherited = { "path" => "outputs/inherited.json", "size" => 2, "sha256" => "1" * 64 }
      current = { "path" => "outputs/current.json", "size" => 3, "sha256" => "2" * 64 }
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1).with(
        "inherited_outputs" => [ inherited ], "current_outputs" => [ current ]
      )

      successor = dispatcher.dispatch_successor(
        predecessor: lost, task: task, project: "demo", argv: [ "hive", "run", task.slug ],
        request_id: "request-two", provider: "codex", inherited_outputs: [], now: NOW + 2
      )

      assert_equal [ inherited, current ], successor.attempt["inherited_outputs"]
    end
  end

  def test_successor_chain_is_not_blocked_by_an_older_lost_ancestor
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      first_lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)
      second = dispatcher.dispatch_successor(
        predecessor: first_lost, task: task, project: "demo",
        argv: [ "hive", "run", task.slug ], request_id: "request-two",
        provider: "codex", retry_charge: 1, now: NOW + 2
      )
      second_lost = store.mark_lost(second.attempt, reason: "owner_gone", now: NOW + 3)

      third = dispatcher.dispatch_successor(
        predecessor: second_lost, task: task, project: "demo",
        argv: [ "hive", "run", task.slug ], request_id: "request-three",
        provider: "codex", retry_charge: 2, now: NOW + 4
      )

      assert_equal :accepted, third.status
      assert_equal "attempt-three", third.attempt.attempt_id
      assert_equal second.attempt.attempt_id, third.attempt["predecessor_attempt_id"]
      assert_equal 3, launcher.launched.size
    end
  end

  def test_dispatch_request_routes_normal_and_lost_predecessor_deliveries
    with_dispatcher do |dispatcher, launcher, task, store|
      dispatcher.instance_variable_set(:@task_resolver, ->(_request) { task })
      dispatcher.define_singleton_method(:provider_for) { |_task| "codex" }
      request = FakeRequest.new(
        slug: task.slug, project: "demo", argv: [ "hive", "run", task.slug ],
        request_id: "request-one", inherited_outputs: []
      )
      first = dispatcher.dispatch_request(request, now: NOW)
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)
      successor_request = request.dup
      successor_request.request_id = "request-two"
      successor_request.task_generation = lost.task_generation
      successor_request.predecessor_attempt_id = lost.attempt_id

      successor = dispatcher.dispatch_request(successor_request, interactive: true, now: NOW + 2)

      assert_equal :accepted, successor.status
      assert_equal lost.attempt_id, successor.attempt["predecessor_attempt_id"]
      assert_equal 2, launcher.launched.size
    end
  end

  def test_lost_generation_and_invalid_successor_are_deferred
    with_dispatcher do |dispatcher, _launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)

      ordinary = dispatch(dispatcher, task, request_id: "request-two")
      assert_equal "attempt_lost", ordinary.reason
      assert_equal lost.attempt_id, ordinary.attempt.attempt_id
    end

    with_dispatcher do |dispatcher, _launcher, task|
      with_tmp_dir do |other_root|
        other_store = Hive::Attempts::Store.new(root: other_root)
        generation = Hive::Attempts::Generation.resolve(
          task: task, project: "demo", intended_stage: "4-execute"
        )
        external = other_store.create_launching(
          attempt_id: "external", request_id: "external", predecessor_attempt_id: nil,
          task_id: task.id.to_s, project: "demo", task_slug: task.slug,
          intended_stage: "4-execute",
          task_generation: generation.task_generation,
          progress_token: generation.progress_token,
          provider: "codex", worker_argv: [ "hive", "run", task.slug ],
          claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
          starting_revision: nil, retry_charge: 0,
          inherited_outputs: [], launch_timeout_sec: 30, now: NOW
        )
        external = other_store.mark_lost(external, reason: "owner_gone", now: NOW + 1)
        result = dispatcher.dispatch_successor(
          predecessor: external, task: task, project: "demo",
          argv: [ "hive", "run", task.slug ], request_id: "successor",
          provider: "codex", now: NOW + 2
        )
        assert_equal "invalid_predecessor", result.reason
      end
    end
  end

  def test_legacy_locator_semantic_duplicates_and_resolution_helpers
    with_dispatcher do |dispatcher, launcher, task|
      task.id = nil
      first = dispatch(dispatcher, task, request_id: "request-one")
      duplicate = dispatch(dispatcher, task, request_id: "request-two")
      assert_equal :accepted, first.status
      assert_equal :existing_live, duplicate.status
      assert_equal 1, launcher.launched.size

      request = Struct.new(:slug, :project).new(task.slug, "demo")
      resolver = Struct.new(:task) { def resolve = task }.new(task)
      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { resolver }) do
        assert_equal task, dispatcher.send(:resolve_request_task, request)
      end

      with_replaced_singleton_method(Hive::Config, :load, ->(_root) { { "execute" => { "agent" => "pi" } } }) do
        task.project_root = "/project"
        assert_equal "pi", dispatcher.send(:provider_for, task)
      end
      assert_equal "4-execute", dispatcher.send(:intended_stage_for, [ "hive", "run" ], task)
      assert_equal "4-execute", dispatcher.send(:intended_stage_for, [ "hive", "unknown" ], task)
    end
  end

  def test_starting_revision_reads_git_and_tolerates_process_errors
    with_dispatcher do |dispatcher, _launcher, task|
      with_tmp_git_repo do |worktree|
        task.worktree_path = worktree
        assert_match(/\A[0-9a-f]{40}\z/, dispatcher.send(:starting_revision, task))
      end

      with_tmp_dir do |not_git|
        task.worktree_path = not_git
        assert_nil dispatcher.send(:starting_revision, task)
      end

      task.worktree_path = "/existing"
      with_replaced_singleton_method(File, :directory?, ->(_path) { true }) do
        with_replaced_singleton_method(IO, :popen, ->(*_args, **_kwargs) { raise Errno::EACCES }) do
          assert_nil dispatcher.send(:starting_revision, task)
        end
      end
    end
  end

  def test_default_attempt_id_generator_produces_a_uuid
    dispatcher = Hive::Attempts::Dispatcher.new(store: Object.new, launcher: Object.new)
    assert_match(/\A[0-9a-f-]{36}\z/, dispatcher.instance_variable_get(:@id_generator).call)
  end

  def test_execute_dispatch_bridges_numeric_input_epoch_without_replacing_ownership_generation
    with_dispatcher do |dispatcher, _launcher, task|
      result = dispatch(dispatcher, task, request_id: "request-one")

      assert_equal 1, result.attempt.task_input_epoch
      assert_equal result.attempt.task_generation, result.attempt.ownership_generation
      assert_match(/\A[0-9a-f]{64}\z/, result.attempt.ownership_generation)
    end
  end

  private

  def with_dispatcher(limits: { max_global: 3, max_per_project: 2, max_daily: 50 })
    with_tmp_dir do |root|
      state_file = File.join(root, "task.md")
      File.write(state_file, "task\n<!-- WAITING -->\n")
      task = FakeTask.new(id: 42, slug: "durable-task", state_file: state_file,
                          stage_index: 4, stage_name: "execute")
      store = Hive::Attempts::Store.new(root: File.join(root, "attempts"))
      launcher = FakeLauncher.new
      ids = %w[attempt-one attempt-two attempt-three].each
      dispatcher = Hive::Attempts::Dispatcher.new(
        store: store, launcher: launcher, limits: limits, clock: -> { NOW },
        id_generator: -> { ids.next }, capability_generator: -> { CLAIM_CAPABILITY }
      )
      yield dispatcher, launcher, task, store
    end
  end

  def dispatch(dispatcher, task, request_id:, interactive: false, intended_stage: "4-execute",
               generation: nil)
    dispatcher.dispatch(
      task: task, project: "demo", intended_stage: intended_stage,
      argv: [ "hive", "run", task.slug ], request_id: request_id,
      provider: "codex", interactive: interactive, generation: generation, now: NOW
    )
  end

  def terminalize_attempt(store, launcher, result, outcome:, exit_status:, now:)
    capability = launcher.launched.find do |record, _claim_capability|
      record.attempt_id == result.attempt.attempt_id
    end.fetch(1)
    owner = {
      "pid" => Process.pid,
      "start_fingerprint" => "start",
      "session_id" => Process.getsid(0),
      "process_group_id" => Process.getpgrp
    }
    claimed = store.claim(
      result.attempt,
      owner: owner,
      claim_capability: capability,
      first_heartbeat_timeout_sec: 30,
      now: now - 2
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: now - 1)
    store.terminalize(
      running,
      outcome: outcome,
      exit_status: exit_status,
      final_checkpoint: {
        "revision" => "b" * 40,
        "progress_token" => result.attempt["progress_token"]
      },
      output_references: [],
      log_reference: {
        "path" => "logs/#{result.attempt.attempt_id}.frames",
        "size" => 0,
        "sha256" => "0" * 64
      },
      now: now
    )
  end
end
