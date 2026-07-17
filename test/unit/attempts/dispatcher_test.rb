require "test_helper"
require "hive/attempts/dispatcher"

class AttemptsDispatcherTest < Minitest::Test
  include HiveTestHelper
  NOW = Time.utc(2026, 7, 17, 12, 0, 0)
  Task = Struct.new(
    :id, :slug, :state_file, :stage_index, :stage_name, :project_root, :worktree_path,
    keyword_init: true
  )
  Request = Struct.new(
    :slug, :project, :argv, :request_id, :task_generation,
    :predecessor_attempt_id, :inherited_outputs,
    keyword_init: true
  )

  class Launcher
    attr_reader :launched
    def initialize = @launched = []
    def preflight! = true
    def launch(record, argv:) = @launched << [ record, argv ]
  end

  def test_normal_dispatch_deduplicates_live_generation
    with_dispatcher do |dispatcher, launcher, task, _store|
      first = dispatch(dispatcher, task, request_id: "one")
      duplicate = dispatch(dispatcher, task, request_id: "two")

      assert_equal :accepted, first.status
      assert_equal :existing_live, duplicate.status
      assert_equal first.attempt.attempt_id, duplicate.attempt.attempt_id
      assert_equal 1, launcher.launched.length
    end
  end

  def test_capacity_defers_before_attempt_creation
    with_dispatcher(limits: { max_global: 0 }) do |dispatcher, launcher, task, store|
      result = dispatch(dispatcher, task, request_id: "one")
      assert_equal :deferred, result.status
      assert_equal "capacity", result.reason
      assert_empty launcher.launched
      assert_empty store.scan.records
    end
  end

  def test_terminal_receipt_replays_without_launch
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "one")
      terminal = terminalize(store, first.attempt, outcome: "succeeded", exit_status: 0)

      replay = dispatch(dispatcher, task, request_id: "two")
      assert_equal :terminal_replay, replay.status
      assert_equal terminal.receipt, replay.receipt
      assert_equal 1, launcher.launched.length
    end
  end

  def test_lost_predecessor_request_cannot_bypass_coordinator
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "one")
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)
      dispatcher.instance_variable_set(:@task_resolver, ->(_request) { task })
      request = Request.new(
        slug: task.slug, project: "demo", argv: [ "hive", "run", task.slug ],
        request_id: "two", task_generation: lost.task_generation,
        predecessor_attempt_id: lost.attempt_id, inherited_outputs: []
      )

      result = dispatcher.dispatch_request(request, now: NOW + 2)

      assert_equal :deferred, result.status
      assert_equal "retry_authorization_required", result.reason
      assert_equal 1, launcher.launched.length
    end
  end

  def test_typed_authorization_claims_successor_before_launch
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "one")
      failed = terminalize(store, first.attempt, outcome: "failed", exit_status: 1)
      authorization = authorization_for(failed)
      claimed = nil

      result = dispatcher.dispatch_authorized_successor(
        authorization: authorization, predecessor: failed, task: task,
        project: "demo", argv: [ "hive", "run", task.slug ],
        request_id: "two", provider: "codex", now: NOW + 5,
        on_claim: ->(attempt) { claimed = attempt; assert_equal 1, launcher.launched.length }
      )

      assert_equal :accepted, result.status
      assert_equal result.attempt.attempt_id, claimed.attempt_id
      assert_equal failed.attempt_id, result.attempt["predecessor_attempt_id"]
      assert_equal 2, launcher.launched.length
    end
  end

  def test_untyped_authorization_is_rejected
    with_dispatcher do |dispatcher, _launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "one")
      failed = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)
      assert_raises(Hive::Attempts::InvalidSuccessorAuthorization) do
        dispatcher.dispatch_authorized_successor(
          authorization: Object.new, predecessor: failed, task: task,
          project: "demo", argv: [ "hive", "run", task.slug ],
          request_id: "two", provider: "codex", now: NOW + 2
        )
      end
    end
  end

  private

  def with_dispatcher(limits: {})
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      task = Task.new(
        id: 42, slug: "task-a", state_file: File.join(dir, "task.md"),
        stage_index: 4, stage_name: "execute", project_root: dir, worktree_path: nil
      )
      launcher = Launcher.new
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      ids = %w[attempt-one attempt-two attempt-three].each
      dispatcher = Hive::Attempts::Dispatcher.new(
        store: store, launcher: launcher,
        limits: { max_global: 3, max_per_project: 3, max_daily: 50 }.merge(limits),
        clock: -> { NOW }, id_generator: -> { ids.next }, task_resolver: ->(_request) { task }
      )
      dispatcher.define_singleton_method(:provider_for) { |_task| "codex" }
      yield dispatcher, launcher, task, store
    end
  end

  def dispatch(dispatcher, task, request_id:)
    dispatcher.dispatch(
      task: task, project: "demo", intended_stage: "4-execute",
      argv: [ "hive", "run", task.slug ], request_id: request_id,
      provider: "codex", now: NOW
    )
  end

  def terminalize(store, attempt, outcome:, exit_status:)
    owner = {
      "pid" => Process.pid, "start_fingerprint" => "start",
      "session_id" => Process.getsid(0), "process_group_id" => Process.getpgrp
    }
    claimed = store.claim(attempt, owner: owner, first_heartbeat_timeout_sec: 30, now: NOW + 1)
    running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW + 2)
    store.terminalize(
      running, outcome: outcome, exit_status: exit_status,
      final_checkpoint: running.checkpoint, output_references: [],
      log_reference: { "path" => "logs/a.frames", "size" => 0, "sha256" => "0" * 64 },
      now: NOW + 3
    )
  end

  def authorization_for(attempt)
    Struct.new(
      :token, :project, :task_slug, :stage, :generation, :predecessor_attempt_id,
      keyword_init: true
    ).new(
      token: "auth-1", project: "demo", task_slug: "task-a", stage: "4-execute",
      generation: attempt.task_input_epoch, predecessor_attempt_id: attempt.attempt_id
    )
  end
end
