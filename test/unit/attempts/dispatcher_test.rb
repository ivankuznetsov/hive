require "test_helper"
require "hive/attempts/context"
require "hive/attempts/dispatcher"
require "hive/attempts/failure_cohort_reconciler"
require "hive/attempts/reconciler"
require "hive/patrol_fix/receipt_store"
require "hive/workflows/patrol_fix"

class AttemptsDispatcherTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64
  FakeTask = Struct.new(
    :id, :slug, :state_file, :stage_index, :stage_name, :project_root, :worktree_path,
    :workflow, :folder, keyword_init: true
  )
  FakeRequest = Struct.new(
    :slug, :project, :argv, :request_id, :task_generation,
    :predecessor_attempt_id, :inherited_outputs, :recovery,
    :requestor, :trigger,
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

  def test_claim_window_starts_after_prelaunch_context_capture
    wall_time = NOW
    context_provenance = Object.new
    context_provenance.define_singleton_method(:capture_launch) do |**_attributes|
      wall_time = NOW + 45
    end

    with_dispatcher(
      context_provenance: context_provenance,
      clock: -> { wall_time }
    ) do |dispatcher, launcher, task|
      task.folder = File.dirname(task.state_file)
      task.project_root = task.folder
      result = dispatch(dispatcher, task, request_id: "request-one")
      launched = launcher.launched.fetch(0).fetch(0)

      assert_equal :accepted, result.status
      assert_equal NOW.iso8601(6), launched["accepted_at"]
      assert_equal (NOW + 75).iso8601(6), launched["claim_deadline"]
    end
  end

  def test_changed_generation_waits_for_live_stage_owner_instead_of_attaching
    with_dispatcher do |dispatcher, launcher, task|
      first = dispatch(dispatcher, task, request_id: "request-one")
      File.write(task.state_file, "changed\n<!-- WAITING -->\n")
      changed = dispatch(dispatcher, task, request_id: "request-two")

      assert_equal :deferred, changed.status
      assert_equal "in_flight", changed.reason
      assert_equal first.attempt.attempt_id, changed.attempt.attempt_id
      assert_nil changed.attach_descriptor
      assert_equal 1, launcher.launched.size
    end
  end

  def test_plan_review_attempt_generation_advances_with_review_projection
    with_dispatcher do |dispatcher, launcher, task, store|
      task.stage_index = 3
      task.stage_name = "plan"
      task.folder = File.dirname(task.state_file)
      task.project_root = task.folder
      review_dir = File.join(task.folder, "plan-review")
      FileUtils.mkdir_p(review_dir)
      current_path = File.join(review_dir, "current.json")
      review_id = "pr-#{'a' * 64}"
      File.write(
        current_path,
        JSON.generate("review_id" => review_id, "state" => "verifying", "version" => 1)
      )
      dispatcher.instance_variable_set(:@task_resolver, ->(_request) { task })
      dispatcher.define_singleton_method(:provider_for) { |_task| "pi" }
      request = lambda do |id|
        FakeRequest.new(
          slug: task.slug, project: "demo",
          argv: [ "hive", "plan-review-run", task.slug ], request_id: id,
          inherited_outputs: []
        )
      end

      first = dispatcher.dispatch_request(request.call("review-one"), now: NOW)
      terminalize_attempt(
        store, launcher, first, outcome: "succeeded", exit_status: 0, now: NOW + 3
      )
      replay = dispatcher.dispatch_request(request.call("review-two"), now: NOW + 4)
      File.write(
        current_path,
        JSON.generate("review_id" => review_id, "state" => "verifying", "version" => 2)
      )
      retry_result = dispatcher.dispatch_request(request.call("review-three"), now: NOW + 5)

      assert_equal :terminal_replay, replay.status
      assert_equal :accepted, retry_result.status
      refute_equal first.attempt.task_generation, retry_result.attempt.task_generation
      assert_equal 2, launcher.launched.length
    end
  end

  def test_patrol_fix_attempt_generation_advances_with_receipt_journal
    with_dispatcher do |dispatcher, launcher, task, store|
      task.stage_index = 1
      task.stage_name = "inbox"
      task.folder = File.dirname(task.state_file)
      task.workflow = Hive::Workflows::PatrolFix::DESCRIPTOR
      patrol_store = Hive::PatrolFix::ReceiptStore.new(task_folder: task.folder)

      first = dispatcher.dispatch(
        task: task, project: "demo", intended_stage: "1-inbox",
        argv: [ "hive", "run", task.slug ], request_id: "patrol-run",
        provider: "pi", interactive: false, now: NOW
      )
      terminalize_attempt(
        store, launcher, first, outcome: "succeeded", exit_status: 0, now: NOW + 3
      )
      replay = dispatcher.dispatch(
        task: task, project: "demo", intended_stage: "1-inbox",
        argv: [ "hive", "approve", task.slug, "--from", "1-inbox", "--force" ],
        request_id: "patrol-advance-before-receipt", provider: "pi",
        interactive: false, now: NOW + 4
      )
      patrol_store.append!(patrol_fix_decision_receipt(task.slug))
      advance = dispatcher.dispatch(
        task: task, project: "demo", intended_stage: "1-inbox",
        argv: [ "hive", "approve", task.slug, "--from", "1-inbox", "--force" ],
        request_id: "patrol-advance-after-receipt", provider: "pi",
        interactive: false, now: NOW + 5
      )

      assert_equal :terminal_replay, replay.status
      assert_equal :accepted, advance.status
      refute_equal first.attempt.task_generation, advance.attempt.task_generation
      assert_equal 2, launcher.launched.length
      worker_context = Hive::Attempts::Context.send(
        :new,
        attempt_id: advance.attempt.attempt_id,
        task_generation: advance.attempt.task_input_epoch,
        ownership_generation: advance.attempt.ownership_generation,
        project: "demo", task_slug: task.slug, intended_stage: "1-inbox",
        progress_token: advance.attempt["progress_token"]
      )
      with_replaced_singleton_method(
        Hive::Attempts::Generation, :default_attempt_store, -> { store }
      ) do
        assert worker_context.validate_generation!(task)
      end
    end
  end

  # The review projection is the plan-review progress token's only moving
  # part, so an absent or unreadable current.json must still yield a stable,
  # distinct token. Failing closed to the artifact token would make a
  # markerless review replay forever; raising would strand the dispatch.
  def test_plan_review_progress_token_survives_missing_and_unreadable_projection
    with_dispatcher do |dispatcher, _launcher, task|
      task.folder = File.dirname(task.state_file)
      review_argv = [ "hive", "plan-review-run", task.slug ]
      base = dispatcher.send(:command_progress_token, [ "hive", "run", task.slug ], task)

      missing = dispatcher.send(:command_progress_token, review_argv, task)

      assert_equal missing, dispatcher.send(:command_progress_token, review_argv, task),
                   "a missing projection must hash deterministically"
      refute_equal base, missing,
                   "the review token must not collapse onto the artifact token"

      # A directory in place of current.json raises EISDIR -- a SystemCallError
      # the ENOENT/ENOTDIR guard deliberately does not swallow.
      FileUtils.mkdir_p(
        File.join(
          task.folder, Hive::PlanReview::Store::ROOT_BASENAME,
          Hive::PlanReview::Store::CURRENT_BASENAME
        )
      )

      unreadable = dispatcher.send(:command_progress_token, review_argv, task)

      assert_equal unreadable, dispatcher.send(:command_progress_token, review_argv, task),
                   "an unreadable projection must hash deterministically"
      refute_equal missing, unreadable
      refute_equal base, unreadable
    end
  end

  def test_launch_context_is_captured_after_attempt_creation_and_before_handoff
    events = []
    provenance = Object.new
    provenance.define_singleton_method(:capture_launch) do |task:, attempt:, generation:,
                                                        attempt_store:, clock:|
      journal = Hive::TaskProjection.read_journal(
        File.join(task.folder, Hive::TaskJournal::JOURNAL_BASENAME),
        attempt_store: attempt_store
      )
      admitted = journal.any? do |record|
        record.dig("payload", "activity_kind") == "attempt_admitted" &&
          record["attempt_id"] == attempt.attempt_id
      end
      events << [ :context, task.slug, attempt.attempt_id, generation.task_generation,
                  !attempt_store.fetch(attempt.attempt_id).nil?, admitted, clock.call ]
    end

    with_dispatcher(context_provenance: provenance) do |dispatcher, launcher, task|
      task.folder = File.dirname(task.state_file)
      task.project_root = task.folder
      original = launcher.method(:launch)
      launcher.define_singleton_method(:launch) do |record, claim_capability:|
        events << [ :launch, record.attempt_id ]
        original.call(record, claim_capability: claim_capability)
      end

      result = dispatch(dispatcher, task, request_id: "capture-order")

      assert_equal :accepted, result.status
      assert_equal :context, events.fetch(0).fetch(0)
      assert_equal [ task.slug, result.attempt.attempt_id, result.attempt.task_generation, true, true, NOW ],
                   events.fetch(0).drop(1)
      assert_equal [ :launch, result.attempt.attempt_id ], events.fetch(1)
    end
  end

  def test_launch_context_failure_does_not_strand_durable_handoff
    provenance = Object.new
    provenance.define_singleton_method(:capture_launch) { |**| raise IOError, "capture failed" }

    with_dispatcher(context_provenance: provenance) do |dispatcher, launcher, task|
      task.folder = File.dirname(task.state_file)
      task.project_root = task.folder

      result = dispatch(dispatcher, task, request_id: "capture-failure")

      assert_equal :accepted, result.status
      assert_equal 1, launcher.launched.length
      assert_equal result.attempt.attempt_id, launcher.launched.first.first.attempt_id
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
        dispatcher, task, request_id: "request-two",
        intended_stage: "2-brainstorm"
      )
      duplicate = dispatch(
        dispatcher, task, request_id: "request-three",
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
        dispatcher, task, request_id: "request-two",
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

  def test_patrol_failure_cohort_survives_restart_and_runtime_change_releases_it
    with_tmp_dir do |root|
      database = attempt_database(root, projects: [ "demo" ])
      store = Hive::Attempts::Repository.new(
        root: File.join(root, "attempts"), database: database
      )
      launcher = FakeLauncher.new
      ids = (1..8).map { |index| "attempt-#{index}" }.each
      runtime_digest = "a" * 64
      dispatcher = Hive::Attempts::Dispatcher.new(
        store: store, launcher: launcher,
        limits: { max_global: 6, max_per_project: 6, max_daily: 50 },
        clock: -> { NOW }, id_generator: -> { ids.next },
        capability_generator: -> { CLAIM_CAPABILITY },
        runtime_digest: runtime_digest
      )
      tasks = 3.times.map do |index|
        task_fixture(
          project_state_root(root, "demo"), id: index + 1,
          slug: "patrol-#{index}", stage: "2-fix"
        ).tap do |task|
          task.workflow = Hive::Workflows::PatrolFix::DESCRIPTOR
        end
      end
      failures = tasks.each_with_index.map do |task, index|
        result = dispatch(
          dispatcher, task, request_id: "failure-#{index}", intended_stage: "2-fix",
          now: NOW + (index * 10)
        )
        terminal = terminalize_attempt(
          store, launcher, result, outcome: "failed", exit_status: 7,
          now: NOW + (index * 10) + 3, diagnostic: true
        )
        assert Hive::Attempts::FailureCohortReconciler.new(store: store).reconcile(
          record: terminal,
          admission: store.reservation_metadata(terminal.attempt_id).fetch("admission")
        )
        result
      end

      capped = Hive::Attempts::Dispatcher.new(
        store: Hive::Attempts::Repository.new(root: store.root, database: database), launcher: launcher,
        limits: { max_global: 6, max_per_project: 6, max_daily: 3 },
        clock: -> { NOW + 40 }, id_generator: -> { ids.next },
        capability_generator: -> { CLAIM_CAPABILITY },
        runtime_digest: runtime_digest
      )
      hard_capped = dispatch(
        capped, tasks.first, request_id: "hard-cap-precedence",
        intended_stage: "2-fix", now: NOW + 40
      )
      assert_equal :deferred, hard_capped.status
      assert_equal "capacity", hard_capped.reason

      restarted = Hive::Attempts::Dispatcher.new(
        store: Hive::Attempts::Repository.new(root: store.root, database: database), launcher: launcher,
        limits: { max_global: 6, max_per_project: 6, max_daily: 50 },
        clock: -> { NOW + 40 }, id_generator: -> { ids.next },
        capability_generator: -> { CLAIM_CAPABILITY },
        runtime_digest: runtime_digest
      )
      blocked = dispatch(
        restarted, tasks.first, request_id: "blocked-retry",
        intended_stage: "2-fix", now: NOW + 40
      )
      assert_equal :deferred, blocked.status
      assert_equal "failure_cohort_cooldown", blocked.reason

      restarted.instance_variable_set(:@task_resolver, ->(_request) { tasks[1] })
      restarted.define_singleton_method(:provider_for) { |_task| "codex" }
      automatic = restarted.dispatch_request(
        FakeRequest.new(
          slug: tasks[1].slug, project: "demo",
          argv: [ "hive", "run", tasks[1].slug ],
          request_id: "automatic-recovery", inherited_outputs: [],
          recovery: { "phase" => "cleared" }, requestor: "action",
          trigger: "recovery/admission_failure"
        ),
        now: NOW + 40
      )
      assert_equal :deferred, automatic.status
      assert_equal "failure_cohort_cooldown", automatic.reason

      restarted_store = restarted.instance_variable_get(:@store)
      original_create = restarted_store.method(:create_launching)
      restarted_store.define_singleton_method(:create_launching) do |**|
        raise Hive::Attempts::RepositoryError, "injected create failure"
      end
      failed_release = FakeRequest.new(
        slug: tasks[1].slug, project: "demo",
        argv: [ "hive", "run", tasks[1].slug ],
        request_id: "failed-operator-release", inherited_outputs: [],
        recovery: { "phase" => "cleared" }, requestor: "action",
        trigger: "recovery"
      )
      assert_raises(Hive::Attempts::RepositoryError) do
        restarted.dispatch_request(failed_release, now: NOW + 40)
      end
      restarted_store.define_singleton_method(:create_launching, original_create)

      launcher.instance_variable_set(
        :@result, { "claimed" => false, "error" => "wrapper unavailable" }
      )
      lost_probe = restarted.dispatch_request(
        FakeRequest.new(
          slug: tasks[1].slug, project: "demo",
          argv: [ "hive", "run", tasks[1].slug ],
          request_id: "lost-operator-release", inherited_outputs: [],
          recovery: { "phase" => "cleared" }, requestor: "action",
          trigger: "recovery"
        ),
        now: NOW + 40
      )
      assert_equal :deferred, lost_probe.status
      assert_equal "launch_handoff_failed", lost_probe.reason
      launcher.instance_variable_set(:@result, { "claimed" => true })

      restarted.instance_variable_set(:@task_resolver, ->(_request) { tasks[2] })
      released_probe = restarted.dispatch_request(
        FakeRequest.new(
          slug: tasks[2].slug, project: "demo",
          argv: [ "hive", "run", tasks[2].slug ],
          request_id: "operator-release", inherited_outputs: [],
          recovery: { "phase" => "cleared" }, requestor: "action",
          trigger: "recovery"
        ),
        now: NOW + 40
      )
      assert_equal :accepted, released_probe.status

      restarted.instance_variable_set(:@task_resolver, ->(_request) { tasks[0] })
      second_release = restarted.dispatch_request(
        FakeRequest.new(
          slug: tasks[0].slug, project: "demo",
          argv: [ "hive", "run", tasks[0].slug ],
          request_id: "operator-release-two", inherited_outputs: [],
          recovery: { "phase" => "cleared" }, requestor: "action",
          trigger: "recovery"
        ),
        now: NOW + 40
      )
      assert_equal :deferred, second_release.status
      assert_equal "failure_cohort_cooldown", second_release.reason

      repaired = Hive::Attempts::Dispatcher.new(
        store: Hive::Attempts::Repository.new(root: store.root, database: database), launcher: launcher,
        limits: { max_global: 6, max_per_project: 6, max_daily: 50 },
        clock: -> { NOW + 41 }, id_generator: -> { ids.next },
        capability_generator: -> { CLAIM_CAPABILITY },
        runtime_digest: "b" * 64
      )
      released = dispatch(
        repaired, tasks.first, request_id: "repaired-retry",
        intended_stage: "2-fix", now: NOW + 41
      )
      assert_equal :accepted, released.status
      refute_includes failures.map { |result| result.attempt.attempt_id },
                      released.attempt.attempt_id
    end
  end

  def test_runtime_source_digest_ignores_deployment_identity_but_tracks_build
    base = {
      "channel" => "dogfood", "release_version" => "1.2.3",
      "display_version" => "1.2.3+dogfood.aaaaaaaaa",
      "build_sha" => "a" * 40, "deployment_id" => "deploy-a"
    }

    first = Hive::Attempts::Dispatcher.runtime_source_digest(base)
    redeployed = Hive::Attempts::Dispatcher.runtime_source_digest(
      base.merge("deployment_id" => "deploy-b")
    )
    repaired = Hive::Attempts::Dispatcher.runtime_source_digest(
      base.merge("build_sha" => "b" * 40)
    )

    assert_equal first, redeployed
    refute_equal first, repaired
  end

  def test_invalid_runtime_digest_is_rejected_before_dispatch
    with_tmp_dir do |root|
      assert_raises(ArgumentError) do
        Hive::Attempts::Dispatcher.new(
          store: Hive::Attempts::Repository.new(
            root: File.join(root, "attempts"), migrate: true
          ),
          launcher: FakeLauncher.new,
          runtime_digest: "invalid"
        )
      end
    end
  end

  def test_already_lost_handoff_defers_and_releases_matching_probe
    with_dispatcher do |dispatcher, _launcher, task, store|
      created = dispatch(dispatcher, task, request_id: "lost-handoff").attempt
      lost = store.mark_lost(created, reason: "owner_gone", now: NOW + 1)
      seed_failure_cohort(store, identity: failure_cohort_identity, date: NOW.to_date)
      assert store.claim_failure_cohort_probe(
        identity: failure_cohort_identity, date: NOW.to_date,
        attempt_id: lost.attempt_id, now: NOW + 4_000
      )
      view = Object.new
      view.define_singleton_method(:record) { |_record| true }

      result = dispatcher.send(
        :resolve_failed_handoff, lost, interactive: false,
        admission_view: view, cohort_identity: failure_cohort_identity,
        cohort_date: NOW.to_date
      )

      assert_equal :deferred, result.status
      assert_equal "launch_handoff_failed", result.reason
      assert store.claim_failure_cohort_probe(
        identity: failure_cohort_identity, date: NOW.to_date,
        attempt_id: lost.attempt_id, now: NOW + 4_001, explicit_release: true
      )
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
      racing_store.define_singleton_method(:fetch_hot) { |_attempt_id| fetches.shift }
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
      assert_equal lost.task_input_epoch, successor.attempt.task_input_epoch
      assert_equal lost.attempt_id, successor.attempt["predecessor_attempt_id"]
      assert_equal [ capture ], successor.attempt["inherited_outputs"]
      assert_equal 2, successor.attempt["retry_charge"]
      assert_equal 2, launcher.launched.size
    end
  end

  def test_existing_successor_prevents_a_second_successor_for_the_same_loss
    with_dispatcher do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)
      successor = dispatcher.dispatch_successor(
        predecessor: lost, task: task, project: "demo",
        argv: [ "hive", "run", task.slug ], request_id: "request-two",
        provider: "codex", now: NOW + 2
      )
      store.mark_lost(successor.attempt, reason: "handoff_failed", now: NOW + 3)

      duplicate = dispatcher.dispatch_successor(
        predecessor: lost, task: task, project: "demo",
        argv: [ "hive", "run", task.slug ], request_id: "request-three",
        provider: "codex", now: NOW + 4
      )

      assert_equal :deferred, duplicate.status
      assert_equal "successor_exists", duplicate.reason
      assert_equal successor.attempt.attempt_id, duplicate.attempt.attempt_id
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
      successor_request.recovery = { "retry_count" => 3 }

      successor = dispatcher.dispatch_request(successor_request, interactive: true, now: NOW + 2)

      assert_equal :accepted, successor.status
      assert_equal lost.attempt_id, successor.attempt["predecessor_attempt_id"]
      assert_equal 3, successor.attempt["retry_charge"]
      assert_equal 2, launcher.launched.size
    end
  end

  def test_lost_generation_and_invalid_successor_are_deferred
    with_dispatcher do |dispatcher, _launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      lost = store.mark_lost(first.attempt, reason: "owner_gone", now: NOW + 1)

      # An ordinary dispatch adopts the loss rather than deferring behind it:
      # nothing else mints the successor, so deferring parks the task forever.
      ordinary = dispatch(dispatcher, task, request_id: "request-two")
      assert_equal :accepted, ordinary.status
      assert_equal lost.attempt_id, ordinary.attempt["predecessor_attempt_id"]
    end

    with_dispatcher do |dispatcher, _launcher, task|
      with_tmp_dir do |other_root|
        other_store = Hive::Attempts::Repository.new(root: other_root, migrate: true)
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

  def test_shared_admission_view_applies_multi_admission_capacity_delta_without_rescanning
    with_dispatcher(limits: { max_global: 2, max_per_project: 2, max_daily: 2 }) do |dispatcher, launcher, task, store|
      scans = 0
      original_scan = store.method(:scan)
      store.define_singleton_method(:scan) do
        scans += 1
        original_scan.call
      end
      admission_view = Hive::Attempts::Reconciler.new(store: store).reconcile(now: NOW).admission_view
      state_root = task_state_root(task)
      second_task = task_fixture(state_root, id: 43, slug: "durable-task-two")
      third_task = task_fixture(state_root, id: 44, slug: "durable-task-three")

      first = dispatch(
        dispatcher, task, request_id: "request-one", admission_view: admission_view
      )
      second = dispatch(
        dispatcher, second_task, request_id: "request-two", admission_view: admission_view
      )
      blocked = dispatch(
        dispatcher, third_task, request_id: "request-three", admission_view: admission_view
      )

      assert_equal [ :accepted, :accepted, :deferred ], [ first.status, second.status, blocked.status ]
      assert_equal "capacity", blocked.reason
      assert_equal 2, launcher.launched.size
      assert_equal 1, scans
    end
  end

  def test_stale_tick_view_observes_external_dispatch_through_live_capacity_cell
    with_tmp_dir do |root|
      database = attempt_database(root, projects: %w[external daemon])
      attempt_root = File.join(root, "attempts")
      tick_store = Hive::Attempts::Repository.new(root: attempt_root, database: database)
      external_store = Hive::Attempts::Repository.new(root: attempt_root, database: database)
      tick_scans = 0
      external_scans = 0
      tick_scan = tick_store.method(:scan)
      external_scan = external_store.method(:scan)
      tick_store.define_singleton_method(:scan) do
        tick_scans += 1
        tick_scan.call
      end
      external_store.define_singleton_method(:scan) do
        external_scans += 1
        external_scan.call
      end
      admission_view = Hive::Attempts::Reconciler.new(store: tick_store)
                                                  .reconcile(now: NOW)
                                                  .admission_view
      assert_equal 1, tick_scans
      assert_equal 0, external_scans

      external_task = task_fixture(project_state_root(root, "external"), id: 41, slug: "external-task")
      daemon_task = task_fixture(project_state_root(root, "daemon"), id: 42, slug: "daemon-task")
      limits = { max_global: 1, max_per_project: 1, max_daily: 50 }
      external = Hive::Attempts::Dispatcher.new(
        store: external_store, launcher: FakeLauncher.new, limits: limits,
        id_generator: -> { "external-attempt" },
        capability_generator: -> { CLAIM_CAPABILITY }
      )
      daemon = Hive::Attempts::Dispatcher.new(
        store: tick_store, launcher: FakeLauncher.new, limits: limits,
        id_generator: -> { "daemon-attempt" },
        capability_generator: -> { CLAIM_CAPABILITY }
      )

      external_result = external.dispatch(
        task: external_task, project: "external", intended_stage: "4-execute",
        argv: [ "hive", "run", external_task.slug ], request_id: "external-request",
        provider: "codex", now: NOW + 1
      )
      assert_equal :accepted, external_result.status
      assert_equal 1, external_scans

      daemon_result = daemon.dispatch(
        task: daemon_task, project: "daemon", intended_stage: "4-execute",
        argv: [ "hive", "run", daemon_task.slug ], request_id: "daemon-request",
        provider: "codex", now: NOW + 2, admission_view: admission_view
      )

      assert_equal :deferred, daemon_result.status
      assert_equal "capacity", daemon_result.reason
      assert_equal 1, tick_scans,
                   "the daemon must not rescan its stale tick view"
      assert_equal 1, external_scans,
                   "the direct dispatcher owns its separate admission scan"
    end
  end

  def test_terminal_transition_releases_active_capacity
    with_dispatcher(limits: { max_global: 1, max_per_project: 1, max_daily: 50 }) do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      terminalize_attempt(
        store, launcher, first, outcome: "failed", exit_status: 1,
        now: NOW + 3
      )
      other_task = task_fixture(task_state_root(task), id: 43, slug: "other-task")
      admission_view = Hive::Attempts::Reconciler.new(store: store)
                                                  .reconcile(now: NOW + 4)
                                                  .admission_view

      result = dispatch(
        dispatcher, other_task, request_id: "request-two",
        admission_view: admission_view
      )

      assert_equal :accepted, result.status
    end
  end

  def test_shared_admission_view_revalidates_terminal_replay_and_loss_successor_semantics
    with_dispatcher do |dispatcher, launcher, task, store|
      admission_view = Hive::Attempts::Reconciler.new(store: store).reconcile(now: NOW).admission_view
      first = dispatch(
        dispatcher, task, request_id: "request-one", admission_view: admission_view
      )
      failed = terminalize_attempt(
        store, launcher, first, outcome: "failed", exit_status: 1, now: NOW + 3
      )

      replay = dispatch(
        dispatcher, task, request_id: "request-one", admission_view: admission_view
      )
      retry_result = dispatch(
        dispatcher, task, request_id: "request-two", admission_view: admission_view
      )
      lost = store.mark_lost(retry_result.attempt, reason: "owner_gone", now: NOW + 4)
      blocked = dispatch(
        dispatcher, task, request_id: "request-three", admission_view: admission_view
      )
      successor = dispatcher.dispatch_successor(
        predecessor: lost, task: task, project: "demo",
        argv: [ "hive", "run", task.slug ], request_id: "request-four",
        provider: "codex", retry_charge: 1, now: NOW + 5,
        admission_view: admission_view
      )

      assert_equal :terminal_replay, replay.status
      assert_equal failed.receipt, replay.receipt
      assert_equal :accepted, retry_result.status
      # The ordinary dispatch adopts the loss, so it becomes the successor...
      assert_equal :accepted, blocked.status
      assert_equal lost.attempt_id, blocked.attempt["predecessor_attempt_id"]
      # ...and an explicit second successor for the same loss spawns nothing
      # new, which is what keeps adoption from racing anything.
      assert_equal :existing_live, successor.status
      assert_equal blocked.attempt.attempt_id, successor.attempt.attempt_id
    end
  end

  def test_admission_queries_terminal_request_and_successful_owner_after_publication
    with_dispatcher do |dispatcher, launcher, task, store|
      failed_result = dispatch(dispatcher, task, request_id: "request-one")
      failed = terminalize_attempt(
        store, launcher, failed_result, outcome: "failed", exit_status: 1,
        now: NOW + 3
      )
      successful_result = dispatch(dispatcher, task, request_id: "request-two")
      successful = terminalize_attempt(
        store, launcher, successful_result, outcome: "succeeded", exit_status: 0,
        now: NOW + 6
      )
      [ failed, successful ].each do |record|
        finish_publication(store, record)
      end
      admission_view = Hive::Attempts::Reconciler.new(store: store)
                                                  .reconcile(now: NOW + 7)
                                                  .admission_view

      exact_request = dispatch(
        dispatcher, task, request_id: "request-one", admission_view: admission_view
      )
      semantic_success = dispatch(
        dispatcher, task, request_id: "request-three", admission_view: admission_view
      )

      assert_equal :terminal_replay, exact_request.status
      assert_equal failed.receipt, exact_request.receipt
      assert_equal :terminal_replay, semantic_success.status
      assert_equal successful.receipt, semantic_success.receipt
      assert_equal 2, launcher.launched.size
    end
  end

  def test_sql_daily_accounting_enforces_utc_capacity_and_tempfail_refund
    with_dispatcher(limits: { max_global: 3, max_per_project: 3, max_daily: 1 }) do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      failed = terminalize_attempt(
        store, launcher, first, outcome: "failed", exit_status: 1,
        now: NOW + 3
      )
      Hive::Attempts::Reconciler.new(store: store).reconcile(now: NOW + 4)
      finish_publication(store, failed)
      admission_view = Hive::Attempts::Reconciler.new(store: store)
                                                  .reconcile(now: NOW + 5)
                                                  .admission_view
      other_task = task_fixture(task_state_root(task), id: 43, slug: "other-task")

      blocked = dispatch(
        dispatcher, other_task, request_id: "request-two",
        admission_view: admission_view,
        now: Time.new(2026, 7, 17, 1, 0, 0, "+14:00")
      )

      assert_equal :deferred, blocked.status
      assert_equal "capacity", blocked.reason
    end

    with_dispatcher(limits: { max_global: 3, max_per_project: 3, max_daily: 1 }) do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      tempfail = terminalize_attempt(
        store, launcher, first, outcome: "failed",
        exit_status: Hive::ExitCodes::TEMPFAIL, now: NOW + 3
      )
      2.times { Hive::Attempts::Reconciler.new(store: store).reconcile(now: NOW + 4) }
      store.refund_tempfail(tempfail)
      finish_publication(store, tempfail)
      admission_view = Hive::Attempts::Reconciler.new(store: store)
                                                  .reconcile(now: NOW + 5)
                                                  .admission_view
      other_task = task_fixture(task_state_root(task), id: 43, slug: "other-task")

      accepted = dispatch(
        dispatcher, other_task, request_id: "request-two",
        admission_view: admission_view,
        now: Time.new(2026, 7, 17, 1, 0, 0, "+14:00")
      )

      assert_equal :accepted, accepted.status
      snapshot = Hive::Attempts::CapacitySnapshot.build(store: store, now: NOW)
      assert_equal 0, snapshot.daily_count("demo", Date.new(2026, 7, 17))
      assert_equal 1, snapshot.daily_count("demo", NOW.utc.to_date)
    end
  end

  def test_tempfail_receipt_defers_a_fresh_request_until_scheduler_backoff_expires
    with_dispatcher(transient_retry_backoff_sec: 60) do |dispatcher, launcher, task, store|
      first = dispatch(dispatcher, task, request_id: "request-one")
      terminal = terminalize_attempt(
        store, launcher, first, outcome: "failed",
        exit_status: Hive::ExitCodes::TEMPFAIL, now: NOW + 3
      )
      Hive::Attempts::Reconciler.new(store: store).reconcile(now: NOW + 4)
      finish_publication(store, terminal)
      admission_view = Hive::Attempts::Reconciler.new(store: store)
                                                  .reconcile(now: NOW + 5)
                                                  .admission_view

      deferred = dispatch(
        dispatcher, task, request_id: "request-two",
        admission_view: admission_view, now: NOW + 62
      )
      accepted = dispatch(
        dispatcher, task, request_id: "request-three",
        admission_view: admission_view, now: NOW + 63
      )
      terminalize_attempt(
        store, launcher, accepted, outcome: "failed", exit_status: 1,
        now: NOW + 66
      )
      retry_after_regular_failure = dispatch(
        dispatcher, task, request_id: "request-four",
        admission_view: admission_view, now: NOW + 67
      )

      assert_equal :deferred, deferred.status
      assert_equal "transient_retry", deferred.reason
      assert_equal first.attempt.attempt_id, deferred.attempt.attempt_id
      assert_equal :accepted, accepted.status
      assert_equal :accepted, retry_after_regular_failure.status
      assert_equal 3, launcher.launched.size
    end
  end

  def test_routing_collaborator_defaults_and_health_attempt_projection_fail_closed
    with_dispatcher do |dispatcher, _launcher, task, store|
      assert_match(
        /\A[0-9a-f-]{36}\z/,
        dispatcher.instance_variable_get(:@decision_id_generator).call
      )

      dispatcher.instance_variable_set(:@routing_policy_resolver, ->(*) { Object.new })
      assert_raises(Hive::ConfigError) do
        dispatcher.send(:resolve_routing_policy, task, "4-execute")
      end
      dispatcher.instance_variable_set(
        :@routing_policy_resolver,
        ->(_task, stage) { Hive::ProviderRouting::Policy.legacy(stage: stage) }
      )

      opened = Object.new
      dispatcher.instance_variable_set(:@health_store, nil)
      with_replaced_singleton_method(
        Hive::ProviderHealth, :open,
        -> { opened }
      ) do
        assert_same opened, dispatcher.send(:provider_health_store)
      end
    end
  end

  private

  def failure_cohort_identity
    {
      "runtime_digest" => "a" * 64,
      "project" => "demo",
      "workflow" => "patrol_fix",
      "stage" => "2-fix",
      "code" => "agent_exit_nonzero"
    }
  end

  def with_dispatcher(limits: { max_global: 3, max_per_project: 2, max_daily: 50 },
                      context_provenance: Hive::ContextProvenance,
                      transient_retry_backoff_sec: 60,
                      clock: -> { NOW })
    with_tmp_dir do |root|
      database = attempt_database(root, projects: [ "demo" ])
      task = task_fixture(project_state_root(root, "demo"), id: 42, slug: "durable-task")
      store = Hive::Attempts::Repository.new(
        root: File.join(root, "attempts"), database: database
      )
      launcher = FakeLauncher.new
      ids = %w[attempt-one attempt-two attempt-three].each
      dispatcher = Hive::Attempts::Dispatcher.new(
        store: store, launcher: launcher, limits: limits, clock: clock,
        id_generator: -> { ids.next }, capability_generator: -> { CLAIM_CAPABILITY },
        context_provenance: context_provenance,
        transient_retry_backoff_sec: transient_retry_backoff_sec
      )
      yield dispatcher, launcher, task, store
    end
  end

  def task_fixture(state_root, id:, slug:, stage: "4-execute")
    folder = File.join(state_root, "stages", stage, slug)
    FileUtils.mkdir_p(folder)
    state_file = File.join(folder, "state.md")
    File.write(state_file, "#{slug}\n<!-- WAITING -->\n")
    FakeTask.new(
      id: id, slug: slug, state_file: state_file,
      stage_index: Integer(stage.split("-", 2).first), stage_name: stage.split("-", 2).last,
      project_root: File.dirname(state_root), folder: folder
    )
  end

  def project_state_root(root, project)
    File.join(root, "projects", project, ".hive-state")
  end

  def task_state_root(task)
    File.dirname(File.dirname(File.dirname(task.folder)))
  end

  def attempt_database(root, projects:)
    database = Hive::RuntimeControlPlane::Database.new(
      path: File.join(root, "runtime-control-plane.sqlite3")
    ).migrate!
    timestamp = Hive::Attempts::Record.iso8601(NOW)
    installation = database.read { |db| db[:installations].get(:installation_id) }
    database.transaction do |db|
      projects.each do |name|
        state_root = project_state_root(root, name)
        FileUtils.mkdir_p(state_root)
        db[:projects].insert(
          project_id: "test-#{name}", installation_id: installation,
          registration_id: "test-#{name}", name: name,
          observed_path: File.dirname(state_root), state_root_path: state_root,
          active: 1, registered_at: timestamp, last_observed_at: timestamp
        )
      end
    end
    database
  end

  def dispatch(dispatcher, task, request_id:, interactive: false, intended_stage: "4-execute",
               generation: nil, admission_view: nil, now: NOW)
    dispatcher.dispatch(
      task: task, project: "demo", intended_stage: intended_stage,
      argv: [ "hive", "run", task.slug ], request_id: request_id,
      provider: "codex", interactive: interactive, generation: generation, now: now,
      admission_view: admission_view
    )
  end

  def terminalize_attempt(store, launcher, result, outcome:, exit_status:, now:,
                          diagnostic: false)
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
    log_reference = {
      "path" => "logs/#{result.attempt.attempt_id}.frames",
      "size" => 0,
      "sha256" => "0" * 64
    }
    output_references = []
    if diagnostic
      document = Hive::PatrolFix::AttemptDiagnostic.normalize(
        { "exit_code" => exit_status, "status" => "error" },
        stage: result.attempt["intended_stage"],
        task_generation: result.attempt.task_generation,
        attempt_id: result.attempt.attempt_id,
        recorded_at: now,
        log_reference: log_reference
      )
      path = store.output_path(
        result.attempt.attempt_id,
        Hive::PatrolFix::AttemptDiagnostic::FILENAME,
        create_directory: true
      )
      File.write(path, JSON.generate(document))
      output_references << Hive::OutputReference.build(path, root: store.root)
    end
    store.terminalize(
      running,
      outcome: outcome,
      exit_status: exit_status,
      final_checkpoint: {
        "revision" => "b" * 40,
        "progress_token" => result.attempt["progress_token"]
      },
      output_references: output_references,
      log_reference: log_reference,
      now: now
    )
  end

  def finish_publication(store, record)
    store.prepare_publication(attempt_id: record.attempt_id, consumers: [ "journal" ])
    store.acknowledge_publication(record.attempt_id, consumer: "journal")
    assert store.finish_publication(record.attempt_id)
  end

  def seed_failure_cohort(store, identity:, date:)
    normalized = Hive::RuntimeControlPlane::Codec.normalize(identity)
    encoded = Hive::RuntimeControlPlane::Codec.dump_json(normalized)
    store.database.transaction do |db|
      db[:attempt_failure_cohorts].insert(
        utc_date: date.iso8601, identity_digest: Digest::SHA256.hexdigest(encoded),
        identity_json: encoded, failure_count: 3,
        retry_at: Hive::Attempts::Record.iso8601(NOW + 3_600),
        updated_at: Hive::Attempts::Record.iso8601(NOW)
      )
    end
  end

  def patrol_fix_decision_receipt(slug)
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => "decision-1", "kind" => "decision", "stage" => "inbox",
      "task" => { "slug" => slug, "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "recorded_at" => "2026-08-20T12:00:00Z",
      "payload" => {
        "route" => "fix", "rationale" => "The finding requires a bounded fix.",
        "evidence" => [ "The focused reproduction still fails." ],
        "blocker_owner" => "inbox_gate", "head_revision" => "b" * 40
      }
    }
  end
end
