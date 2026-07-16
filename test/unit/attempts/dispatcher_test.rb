require "test_helper"
require "hive/attempts/dispatcher"

class AttemptsDispatcherTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  FakeTask = Struct.new(:id, :slug, :state_file, :stage_index, :stage_name, keyword_init: true)

  class FakeLauncher
    attr_reader :launched

    def initialize
      @launched = []
    end

    def preflight! = true

    def launch(record, argv:)
      @launched << [ record, argv ]
      { "claimed" => false }
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
    end
  end

  def test_terminal_duplicate_replays_receipt_without_launch_or_daily_charge
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      owner = { "pid" => Process.pid, "start_fingerprint" => "start",
                "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp }
      claimed = store.claim(first.attempt, owner: owner, first_heartbeat_timeout_sec: 30, now: NOW + 1)
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

  def test_capacity_defers_before_creating_an_attempt
    with_dispatcher(limits: { max_global: 0, max_per_project: 1, max_daily: 10 }) do |dispatcher, launcher, task, store|
      result = dispatch(dispatcher, task, request_id: "request-one")

      assert_equal :deferred, result.status
      assert_equal "capacity", result.reason
      assert_empty launcher.launched
      assert_empty store.scan.records
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
        id_generator: -> { ids.next }
      )
      yield dispatcher, launcher, task, store
    end
  end

  def dispatch(dispatcher, task, request_id:, interactive: false)
    dispatcher.dispatch(
      task: task, project: "demo", intended_stage: "4-execute",
      argv: [ "hive", "run", task.slug ], request_id: request_id,
      provider: "codex", interactive: interactive, now: NOW
    )
  end
end
