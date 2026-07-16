require "test_helper"
require "hive/attempts/dispatcher"
require "hive/attempts/lost_outcome"
require "hive/daemon/stale_agent_healer"

class DaemonAttemptLossHealerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)

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
        lost = lost_attempt(store, retry_charge: 1)
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
        lost = lost_attempt(store, retry_charge: 3)
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

  def lost_attempt(store, retry_charge:)
    attempt = store.create_launching(
      attempt_id: "lost-#{retry_charge}", request_id: "request-#{retry_charge}",
      predecessor_attempt_id: nil, task_id: "42", project: "demo",
      task_slug: "durable-task", intended_stage: "4-execute",
      task_generation: "generation-#{retry_charge}", progress_token: "progress",
      provider: "codex", starting_revision: "abc", retry_charge: retry_charge,
      inherited_outputs: [], launch_timeout_sec: 1, now: NOW
    )
    store.mark_lost(attempt, reason: "launch_timeout", now: NOW + 1)
  end

  def with_task
    with_tmp_dir do |project_root|
      folder = File.join(project_root, ".hive-state", "stages", "4-execute", "durable-task")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "meta.yml"), { "id" => 42 }.to_yaml)
      File.write(File.join(folder, "worktree.yml"), { "path" => project_root }.to_yaml)
      yield Hive::Task.new(folder)
    end
  end
end
