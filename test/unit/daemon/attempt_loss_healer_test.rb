require "test_helper"
require "hive/attempts/dispatcher"
require "hive/attempts/lost_outcome"
require "hive/daemon/stale_agent_healer"

class DaemonAttemptLossHealerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64

  class FakeController
    def running_task?(**) = false
  end

  class FakeLogger
    attr_reader :events

    def initialize = @events = []
    def event(name, **attributes) = @events << [ name, attributes ]
  end

  class FakeProcessor
    def initialize(outcomes, task_folder)
      @outcomes = outcomes
      @task_folder = task_folder
    end

    def process(attempt, now:)
      outcome = @outcomes.ensure_for(attempt, now: now)
      return outcome if Hive::Attempts::LostOutcomeStore::FINAL_STATUSES.include?(outcome["status"])

      @outcomes.update(
        attempt, now: now, status: "ready", task_folder: @task_folder,
        cleanup: "absent", capture_references: []
      )
    end
  end

  class FakeDispatcher
    attr_reader :calls

    Attempt = Data.define(:attempt_id)

    def initialize
      @calls = []
    end

    def dispatch_successor(**attributes)
      @calls << attributes
      Hive::Attempts::DispatchResult.new(
        status: :accepted, attempt: Attempt.new(attempt_id: "successor-1"),
        receipt: nil, attach_descriptor: nil, reason: nil
      )
    end
  end

  def test_repeated_ticks_and_healer_restart_dispatch_exactly_one_budgeted_successor
    with_task do |task|
      with_tmp_dir do |root|
        store = Hive::Attempts::Store.new(root: root)
        lost = lost_attempt(store, retry_charge: 1, task_folder: task.folder)
        outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
        dispatcher = FakeDispatcher.new
        logger = FakeLogger.new
        processor = FakeProcessor.new(outcomes, task.folder)

        first = healer(store, outcomes, processor, dispatcher, logger)
        first.heal_attempt_losses([ lost ], now: NOW + 2)
        first.heal_attempt_losses([ lost ], now: NOW + 3)
        restarted = healer(store, outcomes, processor, dispatcher, logger)
        restarted.heal_attempt_losses([ lost ], now: NOW + 4)

        assert_equal 1, dispatcher.calls.size
        call = dispatcher.calls.first
        assert_equal lost.attempt_id, call.fetch(:predecessor).attempt_id
        assert_equal lost.task_generation, call.fetch(:predecessor).task_generation
        assert_equal 2, call.fetch(:retry_charge)
        assert_equal [ "hive", "run", task.folder ], call.fetch(:argv)
        outcome = outcomes.fetch(lost.attempt_id)
        assert_equal "successor_dispatched", outcome.fetch("status")
        assert_equal "successor-1", outcome.fetch("successor_attempt_id")
      end
    end
  end

  def test_exhausted_generation_budget_stays_durable_and_does_not_dispatch
    with_task do |task|
      with_tmp_dir do |root|
        store = Hive::Attempts::Store.new(root: root)
        lost = lost_attempt(store, retry_charge: 3, task_folder: task.folder)
        outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
        dispatcher = FakeDispatcher.new
        logger = FakeLogger.new
        processor = FakeProcessor.new(outcomes, task.folder)

        healer(store, outcomes, processor, dispatcher, logger)
          .heal_attempt_losses([ lost ], now: NOW + 2)

        assert_empty dispatcher.calls
        assert_equal "exhausted", outcomes.fetch(lost.attempt_id).fetch("status")
        assert logger.events.any? { |name, attrs| name == :marker_heal_exhausted && attrs[:reason] == "attempt_lost" }
      end
    end
  end

  def test_successor_preserves_workflow_argv_before_source_stage_promotion
    with_task(stage: "1-inbox") do |task|
      with_tmp_dir do |root|
        store = Hive::Attempts::Store.new(root: root)
        worker_argv = [ "hive", "brainstorm", task.folder, "--from", "1-inbox", "--json" ]
        lost = lost_attempt(
          store, retry_charge: 0, task_folder: task.folder,
          intended_stage: "2-brainstorm", worker_argv: worker_argv
        )
        outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
        dispatcher = FakeDispatcher.new

        healer(
          store, outcomes, FakeProcessor.new(outcomes, task.folder), dispatcher, FakeLogger.new
        ).heal_attempt_losses([ lost ], now: NOW + 2)

        assert_equal worker_argv, dispatcher.calls.first.fetch(:argv)
      end
    end
  end

  def test_successor_retargets_moved_task_and_drops_satisfied_source_assertion
    with_task(stage: "2-brainstorm") do |task|
      with_tmp_dir do |root|
        old_folder = task.folder.sub("2-brainstorm", "1-inbox")
        worker_argv = [
          "hive", "brainstorm", old_folder, "--from", "1-inbox", "--json",
          "--recover-merged-error-reason", "ci_failed"
        ]
        store = Hive::Attempts::Store.new(root: root)
        lost = lost_attempt(
          store, retry_charge: 0, task_folder: old_folder,
          intended_stage: "2-brainstorm", worker_argv: worker_argv
        )
        outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
        dispatcher = FakeDispatcher.new

        healer(
          store, outcomes, FakeProcessor.new(outcomes, task.folder), dispatcher, FakeLogger.new
        ).heal_attempt_losses([ lost ], now: NOW + 2)

        assert_equal [
          "hive", "brainstorm", task.folder, "--json",
          "--recover-merged-error-reason", "ci_failed"
        ], dispatcher.calls.first.fetch(:argv)
      end
    end
  end

  def test_existing_successor_is_replayed_into_outcome_without_redispatch
    with_task do |task|
      with_tmp_dir do |root|
        store = Hive::Attempts::Store.new(root: root)
        lost = lost_attempt(store, retry_charge: 1, task_folder: task.folder)
        successor = store.create_launching(
          attempt_id: "successor-existing", request_id: "successor-request",
          predecessor_attempt_id: lost.attempt_id, task_id: "42", project: "demo",
          task_slug: "durable-task", intended_stage: "4-execute",
          task_generation: lost.task_generation, progress_token: lost["progress_token"],
          provider: "codex", worker_argv: lost["worker_argv"],
          claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
          starting_revision: "abc", retry_charge: 2,
          inherited_outputs: [], launch_timeout_sec: 30, now: NOW + 2
        )
        outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
        dispatcher = FakeDispatcher.new
        processor = FakeProcessor.new(outcomes, task.folder)

        healer(store, outcomes, processor, dispatcher, FakeLogger.new)
          .heal_attempt_losses([ lost ], now: NOW + 3)

        assert_empty dispatcher.calls
        outcome = outcomes.fetch(lost.attempt_id)
        assert_equal "successor_dispatched", outcome.fetch("status")
        assert_equal successor.attempt_id, outcome.fetch("successor_attempt_id")
      end
    end
  end

  def test_unlocatable_task_becomes_manual_and_processor_errors_are_logged
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      lost = lost_attempt(store, retry_charge: 0, task_folder: "durable-task")
      outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
      dispatcher = FakeDispatcher.new
      logger = FakeLogger.new
      processor = FakeProcessor.new(outcomes, nil)

      with_replaced_singleton_method(Hive::TaskResolver, :new, ->(*_args, **_kwargs) { raise Hive::InvalidTaskPath }) do
        healer(store, outcomes, processor, dispatcher, logger)
          .heal_attempt_losses([ lost ], now: NOW + 2)
      end
      assert_equal "manual", outcomes.fetch(lost.attempt_id).fetch("status")

      broken_processor = Object.new
      broken_processor.define_singleton_method(:process) { |*_args, **_kwargs| raise "capture failed" }
      healer(store, outcomes, broken_processor, dispatcher, logger)
        .heal_attempt_losses([ lost ], now: NOW + 3)
      assert logger.events.any? { |name, attrs| name == :marker_heal_failed && attrs[:error].include?("capture failed") }
    end
  end

  def test_task_fallback_resolves_by_stable_id
    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      lost = lost_attempt(store, retry_charge: 0, task_folder: "durable-task")
      outcomes = Hive::Attempts::LostOutcomeStore.new(store: store)
      service = healer(
        store, outcomes, FakeProcessor.new(outcomes, nil), FakeDispatcher.new, FakeLogger.new
      )
      task = Object.new
      resolver = Struct.new(:task) { def resolve = task }.new(task)
      captured = nil
      with_replaced_singleton_method(Hive::TaskResolver, :new, lambda { |target, **kwargs|
        captured = [ target, kwargs ]
        resolver
      }) do
        assert_same task, service.send(:task_for_attempt, lost, {})
      end
      assert_equal [ "42", { project_filter: "demo" } ], captured
    end
  end

  private

  def healer(store, outcomes, processor, dispatcher, logger)
    Hive::Daemon::StaleAgentHealer.new(
      controller: FakeController.new,
      logger: logger,
      attempt_store: store,
      attempt_dispatcher: dispatcher,
      lost_outcome_store: outcomes,
      lost_outcome_processor: processor
    )
  end

  def lost_attempt(store, retry_charge:, task_folder:, intended_stage: "4-execute", worker_argv: nil)
    worker_argv ||= [ "hive", "run", task_folder ]
    attempt = store.create_launching(
      attempt_id: "lost-#{retry_charge}", request_id: "request-#{retry_charge}",
      predecessor_attempt_id: nil, task_id: "42", project: "demo",
      task_slug: "durable-task", intended_stage: intended_stage,
      task_generation: "generation-#{retry_charge}", progress_token: "progress",
      provider: "codex", worker_argv: worker_argv,
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
      starting_revision: "abc", retry_charge: retry_charge,
      inherited_outputs: [], launch_timeout_sec: 1, now: NOW
    )
    store.mark_lost(attempt, reason: "launch_timeout", now: NOW + 1)
  end

  def with_task(stage: "4-execute")
    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", stage, "durable-task")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), { "id" => 42 }.to_yaml)
      File.write(File.join(folder, "worktree.yml"), { "path" => project_root }.to_yaml)
      yield Hive::Task.new(folder)
    end
  end
end
