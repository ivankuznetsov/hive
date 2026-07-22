require "test_helper"
require "hive/conditions/attempt_observer"
require "hive/attempts/reconciler"
require "hive/attempts/store"

class ConditionsAttemptObserverTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 17, 18, 0, 0)
  CAPABILITY = "c" * 64
  TaskStub = Struct.new(:folder, :state_file, :slug, :id, :workflow, keyword_init: true)

  def test_failed_terminal_attempt_replaces_live_health_and_is_idempotent
    with_tmp_dir do |dir|
      task = build_task(dir)
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      launching = create_attempt(store)
      terminal = terminalize(store, launching, outcome: "failed")
      status = Hive::Attempts::ReconciledAttempt.new(
        attempt: terminal, classification: :terminal,
        owner_status: :not_applicable, evidence: {}
      )
      locator_calls = 0
      observer = Hive::Conditions::AttemptObserver.new(
        store: store,
        task_locator: lambda do |_attempt|
          locator_calls += 1
          task
        end
      )

      assert observer.call(status, now: NOW + 3)
      projection = Hive::TaskProjection::Store.new(
        task_folder: task.folder, attempt_store: store
      ).read
      health = projection.current_condition("AgentHealthy")
      assert_equal "unsatisfied", health.fetch("state")
      assert_equal "attempt_terminal_failed", health.fetch("reason")
      assert_equal false, health.dig("payload", "informational_after_terminal")
      before = File.binread(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
      refute observer.call(status, now: NOW + 4)
      assert_equal before,
                   File.binread(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
      assert_equal 1, locator_calls, "delivered terminal attempts must be skipped before task lookup"

      restarted = Hive::Conditions::AttemptObserver.new(
        store: store, task_locator: ->(_attempt) { task }
      )
      refute restarted.call(status, now: NOW + 5)
      assert_equal before,
                   File.binread(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
    end
  end

  def test_non_execute_live_and_unlocatable_attempts_are_ignored
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      live = create_attempt(store)
      status = Hive::Attempts::ReconciledAttempt.new(
        attempt: live, classification: :reserved,
        owner_status: :not_claimed, evidence: {}
      )
      observer = Hive::Conditions::AttemptObserver.new(
        store: store, task_locator: ->(_attempt) { nil }
      )

      refute observer.call(status, now: NOW)
      lost = store.mark_lost(live, reason: "launch_timeout", now: NOW + 1)
      lost_status = status.with(attempt: lost, classification: :lost)
      refute observer.call(lost_status, now: NOW + 1)
    end
  end

  def test_lost_attempt_replaces_live_health_with_fail_closed_observation
    with_tmp_dir do |dir|
      task = build_task(dir)
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      launching = create_attempt(store)
      lost = store.mark_lost(launching, reason: "launch_timeout", now: NOW + 1)
      status = Hive::Attempts::ReconciledAttempt.new(
        attempt: lost, classification: :lost,
        owner_status: :not_claimed, evidence: {}
      )
      observer = Hive::Conditions::AttemptObserver.new(
        store: store, task_locator: ->(_attempt) { task }
      )

      assert observer.call(status, now: NOW + 1)
      projection = Hive::TaskProjection::Store.new(
        task_folder: task.folder, attempt_store: store
      ).read
      health = projection.current_condition("AgentHealthy")
      assert_equal "unsatisfied", health.fetch("state")
      assert_equal "attempt_lost", health.fetch("reason")
    end
  end

  def test_custom_workflow_named_execute_is_not_observed
    with_tmp_dir do |dir|
      task = build_task(dir)
      task.workflow = Struct.new(:id).new("custom")
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      terminal = terminalize(store, create_attempt(store), outcome: "succeeded")
      status = Hive::Attempts::ReconciledAttempt.new(
        attempt: terminal, classification: :terminal,
        owner_status: :not_applicable, evidence: {}
      )
      observer = Hive::Conditions::AttemptObserver.new(
        store: store, task_locator: ->(_attempt) { task }
      )

      refute observer.call(status, now: NOW + 3)
      refute File.exist?(File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME))
    end
  end

  def test_successor_stays_current_when_its_clock_regresses_and_predecessor_arrives_late
    with_tmp_dir do |dir|
      task = build_task(dir)
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      predecessor = create_attempt(store, now: NOW)
      lost = store.mark_lost(predecessor, reason: "launch_timeout", now: NOW + 1)
      successor = create_attempt(
        store, attempt_id: "attempt-2", request_id: "request-2",
        predecessor_attempt_id: lost.attempt_id, now: NOW - 10
      )
      terminal = terminalize(store, successor, outcome: "succeeded", now: NOW - 10)
      successor_status = Hive::Attempts::ReconciledAttempt.new(
        attempt: terminal, classification: :terminal,
        owner_status: :not_applicable, evidence: {}
      )
      predecessor_status = Hive::Attempts::ReconciledAttempt.new(
        attempt: lost, classification: :lost,
        owner_status: :not_claimed, evidence: {}
      )
      observer = Hive::Conditions::AttemptObserver.new(
        store: store, task_locator: ->(_attempt) { task }
      )

      assert observer.call(successor_status, now: NOW + 2)
      assert observer.call(predecessor_status, now: NOW + 3)

      projection = Hive::TaskProjection::Store.new(
        task_folder: task.folder, attempt_store: store
      ).read
      health = projection.current_condition("AgentHealthy")
      assert_equal "attempt-2", health.fetch("attempt_id")
      assert_equal "satisfied", health.fetch("state")
      superseded = projection["conditions"].fetch("history").find do |fact|
        fact["condition"] == "AgentHealthy" && fact["attempt_id"] == "attempt-1"
      end
      assert_equal "newer_incompatible_attempt", superseded.fetch("superseded_reason")
    end
  end

  def test_default_locator_skips_bad_candidates_and_finds_matching_task
    with_tmp_dir do |dir|
      task = build_task(dir)
      hive_state = File.join(dir, "state")
      %w[1-inbox 2-brainstorm 4-execute].each do |stage|
        FileUtils.mkdir_p(File.join(hive_state, "stages", stage, "task"))
      end
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      terminal = terminalize(store, create_attempt(store), outcome: "succeeded")
      status = Hive::Attempts::ReconciledAttempt.new(
        attempt: terminal, classification: :terminal,
        owner_status: :not_applicable, evidence: {}
      )
      wrong = task.dup
      wrong.id = 99
      task_factory = lambda do |folder|
        case File.basename(File.dirname(folder))
        when "1-inbox" then raise Hive::InvalidTaskPath, "bad candidate"
        when "2-brainstorm" then wrong
        else task
        end
      end

      with_replaced_singleton_method(
        Hive::Config, :find_project, ->(_name) { { "hive_state_path" => hive_state } }
      ) do
        with_replaced_singleton_method(Hive::Task, :new, task_factory) do
          observer = Hive::Conditions::AttemptObserver.new(store: store)
          assert observer.call(status, now: NOW + 3)
        end
      end
    end
  end

  def test_default_locator_and_observation_errors_are_reported_without_raising
    with_tmp_dir do |dir|
      store = Hive::Attempts::Store.new(root: File.join(dir, "attempts"))
      terminal = terminalize(store, create_attempt(store), outcome: "failed")
      status = Hive::Attempts::ReconciledAttempt.new(
        attempt: terminal, classification: :terminal,
        owner_status: :not_applicable, evidence: {}
      )

      with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { nil }) do
        refute Hive::Conditions::AttemptObserver.new(store: store).call(status, now: NOW + 3)
      end

      events = []
      logger = Object.new
      logger.define_singleton_method(:event) { |name, **attrs| events << [ name, attrs ] }
      exploding = ->(_attempt) { raise Hive::InvalidTaskPath, "locator failed" }
      observer = Hive::Conditions::AttemptObserver.new(
        store: store, logger: logger, task_locator: exploding
      )
      refute observer.call(status, now: NOW + 3)
      assert_equal :fatal, events.first.first
      assert_includes events.first.last.fetch(:message), "locator failed"

      warning = capture_io do
        refute Hive::Conditions::AttemptObserver.new(
          store: store, task_locator: exploding
        ).call(status, now: NOW + 3)
      end.last
      assert_includes warning, "condition attempt observation failed"
    end
  end

  private

  def build_task(dir)
    folder = File.join(dir, "task")
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "task.md")
    File.write(state_file, "<!-- ERROR reason=implementer_failed -->\n")
    TaskStub.new(
      folder: folder, state_file: state_file, slug: "task", id: 42,
      workflow: Struct.new(:id).new("coding")
    )
  end

  def create_attempt(store, attempt_id: "attempt-1", request_id: "request-1",
                     predecessor_attempt_id: nil, now: NOW)
    store.create_launching(
      attempt_id: attempt_id, request_id: request_id,
      predecessor_attempt_id: predecessor_attempt_id,
      task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
      task_generation: "owner-1", ownership_generation: "owner-1", task_input_epoch: 1,
      progress_token: "progress", provider: "codex",
      worker_argv: [ "hive", "run", "task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CAPABILITY),
      starting_revision: "a" * 40, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: now
    )
  end

  def terminalize(store, launching, outcome:, now: NOW)
    claimed = store.claim(
      launching, owner: { "pid" => Process.pid },
      claim_capability: CAPABILITY, first_heartbeat_timeout_sec: 30, now: now + 1
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: now + 2)
    store.terminalize(
      running, outcome: outcome, exit_status: outcome == "succeeded" ? 0 : 1,
      final_checkpoint: running.checkpoint,
      output_references: [],
      log_reference: {
        "path" => "logs/#{launching.attempt_id}.frames", "size" => 1, "sha256" => "b" * 64
      },
      now: now + 3
    )
  end
end
