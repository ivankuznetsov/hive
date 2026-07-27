require "test_helper"
require "json"
require "json_schemer"
require "stringio"
require "hive/commands/watch"

class CommandsWatchTest < Minitest::Test
  include HiveTestHelper

  FAKE_IDENTITY_RESOLVER = ->(folder) { [ "test", folder ] }

  class FakeClock
    attr_reader :monotonic

    def initialize
      @now = Time.utc(2026, 7, 20, 12, 0, 0)
      @monotonic = 0.0
    end

    def now = @now

    def advance(seconds)
      @monotonic += seconds
      @now += seconds
    end
  end

  class FakeSource
    attr_reader :fetches

    def initialize(*values)
      @values = values
      @fetches = 0
    end

    def fetch
      @fetches += 1
      value = @values.length > 1 ? @values.shift : @values.first
      raise value if value.is_a?(Exception)

      value
    end
  end

  class BlockingSource
    attr_reader :fetches

    def initialize(initial)
      @initial = initial
      @fetches = 0
    end

    def fetch
      @fetches += 1
      return @initial if @fetches == 1

      sleep 5
    end
  end

  class BlockingFirstSource
    attr_reader :fetches

    def initialize
      @fetches = 0
    end

    def fetch
      @fetches += 1
      sleep 5
    end
  end

  class BrokenPipe
    attr_reader :writes

    def initialize(fail_after:)
      @fail_after = fail_after
      @writes = 0
    end

    def puts(_line)
      @writes += 1
      raise Errno::EPIPE if @writes > @fail_after
    end

    def flush; end
  end

  def test_emits_only_semantic_transitions_then_reserved_settled_final
    initial = task(state: "idle", reason: "ready", generated_at: "2026-07-20T12:00:00Z")
    timestamp_only = task(state: "idle", reason: "ready", generated_at: "2026-07-20T12:00:01Z")
    running = task(state: "running", owner: "agent", reason: "working")
    waiting = task(state: "waiting_on_you", owner: "operator", reason: "choose an option")
    source = FakeSource.new(
      snapshot(initial), snapshot(timestamp_only), snapshot(running), snapshot(waiting)
    )

    events, _clock = run_json_watch(source: source, targets: [ "demo:task" ])

    assert_equal %w[initial transition transition final], events.map { |event| event.fetch("event") }
    assert_equal "running", events[1].dig("targets", 0, "state")
    assert_equal "waiting_on_you", events[2].dig("targets", 0, "state")
    assert_equal "settled", events.last.fetch("reason")
    assert_equal 3, events.last.fetch("sequence"), "final is reserved outside the non-final event count"
    assert_watch_schema(events)
  end

  def test_completion_requires_verified_archive_not_completion_ready
    ready = task(state: "completion_ready", reason: "ready to archive")
    source = FakeSource.new(snapshot(ready), snapshot(nil, archived: [ legacy_task(action: "archived") ]))

    events, = run_json_watch(
      source: source, targets: [ "demo:task" ], until_condition: "completion"
    )

    assert_equal %w[initial transition final], events.map { |event| event.fetch("event") }
    assert_equal true, events[1].dig("targets", 0, "archived")
    assert_equal "completion", events.last.fetch("reason")
  end

  def test_ambiguous_bare_target_lists_exact_alternatives_and_project_scope_resolves
    rows = [ task(project: "alpha", slug: "same"), task(project: "beta", slug: "same") ]
    source = FakeSource.new(snapshot(*rows))
    output = StringIO.new

    error = assert_raises(Hive::Commands::Watch::UsageError) do
      build_watch(source: source, targets: [ "same" ], output: output).call
    end
    assert_includes error.message, "alpha:same"
    assert_includes error.message, "beta:same"

    events, = run_json_watch(
      source: FakeSource.new(snapshot(*rows)), targets: [ "same" ], project: "alpha",
      max_events: 1
    )
    assert_equal [ "alpha:same" ], events.first.fetch("targets").map { |target| target.fetch("target") }
  end

  def test_duplicate_project_slug_across_stages_is_rejected_without_collapsing_rows
    rows = [
      task(
        slug: "same", stage: "4-execute",
        folder: "/tmp/demo/stages/4-execute/same"
      ),
      task(
        slug: "same", stage: "5-open-pr",
        folder: "/tmp/demo/stages/5-open-pr/same"
      )
    ]

    error = assert_raises(Hive::Commands::Watch::UsageError) do
      build_watch(
        source: FakeSource.new(snapshot(*rows)), targets: [ "demo:same" ],
        output: StringIO.new
      ).call
    end

    assert_includes error.message, "4-execute"
    assert_includes error.message, "/tmp/demo/stages/4-execute/same"
    assert_includes error.message, "5-open-pr"
    assert_includes error.message, "/tmp/demo/stages/5-open-pr/same"
  end

  def test_duplicate_project_slug_appearing_during_watch_exhausts_source_budget
    collision = [
      task(slug: "task", id: 41, stage: "4-execute", folder: "/tmp/demo/4-execute/task"),
      task(slug: "task", id: 41, stage: "5-open-pr", folder: "/tmp/demo/5-open-pr/task")
    ]
    source = FakeSource.new(
      snapshot(task(id: 41)), snapshot(*collision), snapshot(*collision), snapshot(*collision)
    )
    output = StringIO.new

    error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) do
      build_watch(source: source, targets: [ "demo:task" ], output: output).call
    end

    assert_includes error.message, "status source unavailable"
    events = json_events(output)
    assert_equal 3, events.count { |event| event["reason"] == "source_failure" }
    assert_equal "status_unavailable", events.last.fetch("reason")
  end

  def test_watch_keeps_selected_task_id_when_a_replacement_reuses_the_slug
    original = task(id: 41)
    replacement = task(id: 42, state: "running", reason: "replacement is running")
    archived_original = legacy_task(id: 41, action: "archived")
    source = FakeSource.new(
      snapshot(original), snapshot(replacement, archived: [ archived_original ])
    )

    events, = run_json_watch(
      source: source, targets: [ "demo:task" ], until_condition: "completion"
    )

    assert_equal %w[initial transition final], events.map { |event| event.fetch("event") }
    assert_equal true, events[1].dig("targets", 0, "archived")
    assert_equal "task is archived", events[1].dig("targets", 0, "reason")
    assert_equal "completion", events.last.fetch("reason")
    refute events.any? { |event| event.dig("targets", 0, "reason") == "replacement is running" }
  end

  def test_watch_does_not_follow_a_replacement_when_the_selected_id_disappears
    original = task(id: 41)
    replacement = task(id: 42, state: "running", reason: "replacement is running")
    source = FakeSource.new(
      snapshot(original), snapshot(replacement), snapshot(replacement), snapshot(replacement)
    )
    output = StringIO.new

    assert_raises(Hive::Commands::Watch::StatusUnavailableError) do
      build_watch(source: source, targets: [ "demo:task" ], output: output).call
    end

    events = json_events(output)
    warnings = events.select { |event| event["reason"] == "task_disappeared" }
    assert_equal 3, warnings.size
    assert warnings.all? { |event| event.dig("targets", 0, "present") == false }
    refute events.any? { |event| event.dig("targets", 0, "reason") == "replacement is running" }
  end

  def test_watch_adopts_a_backfilled_id_for_the_same_physical_task
    with_tmp_dir do |dir|
      folder = File.join(dir, "stages", "4-execute", "task")
      FileUtils.mkdir_p(folder)
      source = FakeSource.new(
        snapshot(task(folder: folder)),
        snapshot(
          task(
            folder: folder, id: 41, state: "waiting_on_you",
            owner: "operator", reason: "choose"
          )
        )
      )
      output = StringIO.new
      watch = build_watch(
        source: source, targets: [ "demo:task" ], output: output,
        identity_resolver: nil
      )

      watch.call

      events = json_events(output)
      assert_equal %w[initial transition final], events.map { |event| event.fetch("event") }
      refute events.any? { |event| event["reason"] == "task_disappeared" }
      assert_equal "41", watch.instance_variable_get(:@selection).first.id
    end
  end

  def test_idless_active_archive_collision_fails_closed_during_watch
    active_folder = "/tmp/demo/4-execute/task"
    archived_folder = "/tmp/demo/9-done/task"
    collision = snapshot(
      task(state: "running", folder: active_folder),
      archived: [ legacy_task(action: "archived", folder: archived_folder) ]
    )
    source = FakeSource.new(snapshot(task(folder: active_folder)), collision, collision, collision)
    output = StringIO.new
    same_physical_task = ->(_folder) { [ "test", "same-task" ] }

    assert_raises(Hive::Commands::Watch::StatusUnavailableError) do
      build_watch(
        source: source, targets: [ "demo:task" ], output: output,
        identity_resolver: same_physical_task
      ).call
    end

    events = json_events(output)
    warnings = events.select { |event| event["reason"] == "source_failure" }
    assert_equal 3, warnings.size
    warnings.each do |event|
      assert_includes event.fetch("message"), "active at 4-execute (#{active_folder})"
      assert_includes event.fetch("message"), "archived at 9-done (#{archived_folder})"
    end
    assert_equal "status_unavailable", events.last.fetch("reason")
  end

  def test_project_selection_is_stable_and_rejects_more_than_one_hundred_targets
    rows = 101.times.map { |index| task(slug: "task-#{index}") }
    source = FakeSource.new(snapshot(*rows))

    error = assert_raises(Hive::Commands::Watch::UsageError) do
      build_watch(source: source, targets: [], project: "demo", output: StringIO.new).call
    end
    assert_match(/at most 100/, error.message)
  end

  def test_event_cap_and_timeout_each_emit_one_reserved_final
    idle_source = FakeSource.new(snapshot(task))
    capped, = run_json_watch(source: idle_source, targets: [ "demo:task" ], max_events: 1)
    assert_equal %w[initial final], capped.map { |event| event.fetch("event") }
    assert_equal "event_cap", capped.last.fetch("reason")

    timed, clock = run_json_watch(
      source: FakeSource.new(snapshot(task)), targets: [ "demo:task" ], timeout: 2, interval: 1
    )
    assert_equal %w[initial final], timed.map { |event| event.fetch("event") }
    assert_equal "timeout", timed.last.fetch("reason")
    assert_equal 2.0, clock.monotonic
  end

  def test_idless_selection_fails_closed_without_physical_identity
    error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) do
      build_watch(
        source: FakeSource.new(snapshot(task)), targets: [ "demo:task" ],
        output: StringIO.new, identity_resolver: ->(_folder) { nil }
      ).call
    end

    assert_includes error.message, "task-directory identity is unavailable"
  end

  def test_source_failure_budget_emits_warnings_final_and_status_unavailable_exit
    source = FakeSource.new(
      snapshot(task), IOError.new("down-1"), IOError.new("down-2"), IOError.new("down-3")
    )
    output = StringIO.new
    clock = FakeClock.new
    watch = build_watch(source: source, targets: [ "demo:task" ], output: output, clock: clock)

    error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) { watch.call }
    events = json_events(output)

    assert_match(/source unavailable/, error.message)
    assert_equal %w[initial source_warning source_warning source_warning final],
                 events.map { |event| event.fetch("event") }
    assert_equal false, events.last.fetch("ok")
    assert_equal "status_unavailable", events.last.fetch("reason")
  end

  def test_source_timeout_error_does_not_impersonate_the_overall_deadline
    source = FakeSource.new(
      snapshot(task), Timeout::Error.new("upstream read timed out"),
      Timeout::Error.new("upstream read timed out"), Timeout::Error.new("upstream read timed out")
    )
    output = StringIO.new

    error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) do
      build_watch(source: source, targets: [ "demo:task" ], output: output).call
    end

    events = json_events(output)
    assert_includes error.message, "status source unavailable"
    assert_equal 3, events.count { |event| event["reason"] == "source_failure" }
    assert_equal false, events.last.fetch("ok")
    assert_equal "status_unavailable", events.last.fetch("reason")
    refute events.any? { |event| event["reason"] == "timeout" }
  end

  def test_overall_timeout_bounds_a_blocked_status_fetch
    source = BlockingSource.new(snapshot(task))
    output = StringIO.new
    clock = Hive::Commands::Watch::Clock.new
    watch = build_watch(
      source: source, targets: [ "demo:task" ], output: output,
      clock: clock, sleeper: ->(seconds) { sleep(seconds) }, timeout: 0.05,
      interval: 0.01
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    watch.call
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.5
    assert_equal 2, source.fetches
    assert_equal "timeout", json_events(output).last.fetch("reason")
  end

  def test_overall_timeout_bounds_the_initial_status_fetch
    source = BlockingFirstSource.new
    output = StringIO.new
    clock = Hive::Commands::Watch::Clock.new
    watch = build_watch(
      source: source, targets: [ "demo:task" ], output: output,
      clock: clock, sleeper: ->(seconds) { sleep(seconds) }, timeout: 0.05,
      interval: 0.01
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) { watch.call }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.5
    assert_equal 1, source.fetches
    assert_includes error.message, "initial status source exceeded the overall timeout"
    assert_empty output.string
  end

  def test_overall_timeout_bounds_initial_physical_identity_resolution
    output = StringIO.new
    clock = Hive::Commands::Watch::Clock.new
    watch = build_watch(
      source: FakeSource.new(snapshot(task)), targets: [ "demo:task" ], output: output,
      clock: clock, sleeper: ->(seconds) { sleep(seconds) }, timeout: 0.05,
      interval: 0.01, identity_resolver: ->(_folder) { sleep 5 }
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) { watch.call }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.5
    assert_includes error.message, "identity resolution exceeded"
    assert_empty output.string
  end

  def test_overall_timeout_bounds_later_physical_identity_resolution
    calls = 0
    resolver = lambda do |folder|
      calls += 1
      next [ "test", folder ] if calls <= 2

      sleep 5
    end
    output = StringIO.new
    clock = Hive::Commands::Watch::Clock.new
    source = FakeSource.new(
      snapshot(task), snapshot(task(id: 41, state: "waiting_on_you", owner: "operator"))
    )
    watch = build_watch(
      source: source, targets: [ "demo:task" ], output: output,
      clock: clock, sleeper: ->(seconds) { sleep(seconds) }, timeout: 0.05,
      interval: 0.01, identity_resolver: resolver
    )

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    watch.call
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    events = json_events(output)
    assert_operator elapsed, :<, 0.5
    assert_equal %w[initial final], events.map { |event| event.fetch("event") }
    assert_equal "timeout", events.last.fetch("reason")
    refute events.any? { |event| event["event"] == "transition" }
  end

  def test_unexplained_disappearance_is_not_completion_and_exhausts_budget
    source = FakeSource.new(
      snapshot(task), snapshot, snapshot, snapshot
    )
    output = StringIO.new
    watch = build_watch(source: source, targets: [ "demo:task" ], output: output)

    assert_raises(Hive::Commands::Watch::StatusUnavailableError) { watch.call }
    events = json_events(output)

    warnings = events.select { |event| event["event"] == "source_warning" }
    assert_equal 3, warnings.size
    assert warnings.all? { |event| event["reason"] == "task_disappeared" }
    refute events.any? { |event| event["reason"] == "completion" }
  end

  def test_rejects_global_json_and_contradictory_qualified_project
    source = FakeSource.new(snapshot(task(project: "alpha")))
    error = assert_raises(Hive::Commands::Watch::UsageError) do
      build_watch(source: source, targets: [ "alpha:task" ], json: true, output: StringIO.new).call
    end
    assert_match(/--json-lines/, error.message)

    error = assert_raises(Hive::Commands::Watch::UsageError) do
      build_watch(
        source: FakeSource.new(snapshot(task(project: "alpha"))),
        targets: [ "alpha:task" ], project: "beta", output: StringIO.new
      ).call
    end
    assert_match(/contradicts --project beta/, error.message)
  end

  def test_human_output_escapes_controls_and_epipe_exits_cleanly
    unsafe = task(
      project: "a\e[2J", state: "waiting_on_you", owner: "operator",
      reason: "choose\nnow"
    )
    output = StringIO.new
    build_watch(
      source: FakeSource.new(snapshot(unsafe)), targets: [ "a\e[2J:task" ],
      output: output, json_lines: false
    ).call
    assert_includes output.string, "\\x1B"
    assert_includes output.string, "\\x0A"
    refute_includes output.string, "\e"

    pipe = BrokenPipe.new(fail_after: 1)
    result = build_watch(
      source: FakeSource.new(snapshot(task)), targets: [ "demo:task" ], output: pipe
    ).call
    assert_equal 0, result
  end

  def test_signal_checker_emits_final_and_preserves_exit_code
    clock = FakeClock.new
    output = StringIO.new
    checker = -> { clock.monotonic >= 1 ? 130 : nil }
    watch = build_watch(
      source: FakeSource.new(snapshot(task)), targets: [ "demo:task" ],
      output: output, clock: clock, signal_checker: checker
    )

    error = assert_raises(SystemExit) { watch.call }
    assert_equal 130, error.status
    final = json_events(output).last
    assert_equal "interrupted", final.fetch("reason")
  end

  def test_default_source_projects_one_collected_compatibility_graph
    projects = [ "/tmp/demo" ]
    full_graph = { "ok" => true, "projects" => [] }
    operational = { "ok" => true, "tasks" => [] }
    calls = []
    status = Object.new
    status.define_singleton_method(:json_payload) do |received|
      calls << [ :json_payload, received ]
      full_graph
    end
    status.define_singleton_method(:operational_payload) do |received, status_payload:|
      calls << [ :operational_payload, received, status_payload ]
      operational
    end

    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { projects }) do
      with_replaced_singleton_method(Hive::Commands::Status, :new, ->(json:) {
        calls << [ :status_new, json ]
        status
      }) do
        result = Hive::Commands::Watch::DefaultSource.new.fetch

        assert_same full_graph, result.full_graph
        assert_same operational, result.operational
      end
    end

    assert_equal [
      [ :status_new, true ],
      [ :json_payload, projects ],
      [ :operational_payload, projects, full_graph ]
    ], calls
  end

  def test_rejects_each_invalid_bounded_watch_option
    base = {
      source: FakeSource.new(snapshot(task)), targets: [ "demo:task" ],
      output: StringIO.new, signal_checker: -> { nil }
    }
    cases = [
      [ { until_condition: "forever" }, /--until must be settled or completion/ ],
      [ { interval: 0 }, /--interval must be a positive finite number/ ],
      [ { max_events: 1.5 }, /--max-events must be a positive integer/ ],
      [ { targets: [], project: "" }, /--project must not be empty/ ],
      [ { targets: [], project: nil }, /pass at least one TARGET/ ],
      [ { targets: [ "" ] }, /TARGET must not be empty/ ]
    ]

    cases.each do |overrides, message|
      error = assert_raises(Hive::Commands::Watch::UsageError) do
        Hive::Commands::Watch.new(**base.merge(overrides)).call
      end
      assert_match message, error.message
    end
  end

  def test_initial_source_errors_and_invalid_snapshots_are_status_unavailable
    sources = [
      [ FakeSource.new(IOError.new("offline")), /initial status source unavailable: IOError: offline/ ],
      [ FakeSource.new(Object.new), /watch source returned an invalid snapshot/ ],
      [ FakeSource.new(Hive::Commands::Watch::SourceSnapshot.new(
        operational: { "ok" => false }, full_graph: { "ok" => true }
      )), /watch source returned an unsuccessful status payload/ ]
    ]

    sources.each do |source, message|
      error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) do
        build_watch(source: source, targets: [ "demo:task" ], output: StringIO.new).call
      end
      assert_match message, error.message
    end

    watch = build_watch(
      source: FakeSource.new(snapshot(task)), targets: [ "demo:task" ],
      output: StringIO.new, timeout: 1
    )
    assert_raises(Hive::Commands::Watch::DeadlineExceeded) do
      watch.send(:within_deadline, -2) { flunk "expired deadlines must not yield" }
    end
  end

  def test_selection_errors_distinguish_unknown_empty_missing_and_incomplete_graphs
    cases = [
      [ snapshot(task), [], { project: "unknown" }, /unknown project "unknown"/ ],
      [ snapshot(nil, archived: [ legacy_task(action: "archived") ]), [],
        { project: "demo" }, /no active tasks selected for project "demo"/ ],
      [ snapshot(task), [ ":missing" ], {}, /qualified TARGET must be PROJECT:SLUG/ ],
      [ snapshot(task), [ "demo:missing" ], {}, /no task matches "demo:missing"/ ],
      [ snapshot(task), [ "missing" ], { project: "demo" }, /no task matches "demo:missing"/ ]
    ]

    cases.each do |source_snapshot, targets, options, message|
      error = assert_raises(Hive::Commands::Watch::UsageError) do
        build_watch(
          source: FakeSource.new(source_snapshot), targets: targets,
          output: StringIO.new, **options
        ).call
      end
      assert_match message, error.message
    end

    incomplete = snapshot(task)
    incomplete.operational.dig("source", "task_graph")["status"] = "partial"
    error = assert_raises(Hive::Commands::Watch::StatusUnavailableError) do
      build_watch(
        source: FakeSource.new(incomplete), targets: [ "demo:missing" ],
        output: StringIO.new
      ).call
    end
    assert_match(/cannot resolve.*incomplete task graph \(partial\)/, error.message)
  end

  def test_candidate_fallback_and_physical_identity_fail_closed
    full_only = snapshot(nil, archived: [ legacy_task(action: "ready_to_run") ])
    watch = build_watch(
      source: FakeSource.new(full_only), targets: [ "demo:task" ], output: StringIO.new
    )
    candidates = watch.send(:candidate_index, full_only)

    assert_equal false, candidates.fetch("demo:task").first.fetch(:archived)

    orphan = snapshot(task(project: "orphan"))
    orphan_candidates = watch.send(:candidate_index, orphan)
    assert watch.send(:known_project?, orphan, "orphan", orphan_candidates)
    assert_nil watch.send(:task_physical_identity, "/definitely/missing/hive-watch-task")
  end

  def test_active_target_projects_provider_and_action_policy_without_secrets
    enriched = task(state: "waiting_on_you", owner: "operator", reason: "choose")
    enriched["provider"] = {
      "name" => "codex", "retry_after" => "2026-07-20T12:05:00Z", "private" => "drop"
    }
    enriched["action"] = {
      "action_id" => "workflow.advance", "risk_class" => "routine_idempotent",
      "confirmation_required" => true, "observation_token" => "drop"
    }

    events, = run_json_watch(source: FakeSource.new(snapshot(enriched)), targets: [ "demo:task" ])
    projected = events.first.fetch("targets").first

    assert_equal({ "name" => "codex", "retry_after" => "2026-07-20T12:05:00Z" },
                 projected.fetch("provider"))
    assert_equal({
      "action_id" => "workflow.advance", "risk_class" => "routine_idempotent",
      "confirmation_required" => true
    }, projected.fetch("action_policy"))
  end

  def test_default_signal_handlers_are_installed_for_the_bounded_call
    traps = []
    trap = lambda do |signal, handler = nil, &block|
      traps << [ signal, handler || :block ]
      block&.call if signal == "TERM"
      "DEFAULT"
    end
    events = nil
    with_replaced_singleton_method(Signal, :trap, trap) do
      events, = run_json_watch(
        source: FakeSource.new(snapshot(task(state: "waiting_on_you", owner: "operator"))),
        targets: [ "demo:task" ], signal_checker: nil
      )
    end

    assert_equal %w[initial final], events.map { |event| event.fetch("event") }
    assert_equal "settled", events.last.fetch("reason")
    assert_equal [
      [ "INT", :block ], [ "TERM", :block ],
      [ "INT", "DEFAULT" ], [ "TERM", "DEFAULT" ]
    ], traps
  end

  private

  def build_watch(source:, targets:, output:, clock: FakeClock.new, project: nil,
                  until_condition: "settled", timeout: 30, max_events: 100,
                  interval: 1, json_lines: true, json: false, signal_checker: -> { nil },
                  sleeper: nil, identity_resolver: FAKE_IDENTITY_RESOLVER)
    sleeper ||= lambda do |seconds|
      clock.respond_to?(:advance) ? clock.advance(seconds) : sleep(seconds)
    end
    Hive::Commands::Watch.new(
      targets: targets,
      project: project,
      until_condition: until_condition,
      timeout: timeout,
      max_events: max_events,
      interval: interval,
      json_lines: json_lines,
      json: json,
      source: source,
      clock: clock,
      sleeper: sleeper,
      output: output,
      signal_checker: signal_checker,
      identity_resolver: identity_resolver
    )
  end

  def run_json_watch(source:, targets:, **options)
    output = StringIO.new
    clock = options.delete(:clock) || FakeClock.new
    build_watch(source: source, targets: targets, output: output, clock: clock, **options).call
    [ json_events(output), clock ]
  end

  def json_events(output)
    output.string.lines.map { |line| JSON.parse(line) }
  end

  def task(project: "demo", slug: "task", state: "idle", owner: "scheduler",
           reason: "ready", generated_at: "2026-07-20T12:00:00Z",
           stage: "4-execute", folder: nil, id: nil)
    folder ||= "/tmp/#{project}/#{slug}"
    {
      "identity" => {
        "project" => project, "slug" => slug, "id" => id,
        "display_name" => slug, "folder" => folder
      },
      "workflow" => "coding",
      "position" => { "stage" => stage, "marker" => "waiting" },
      "liveness" => {
        "status" => state == "running" ? "running" : "not_running",
        "pid" => nil, "attempt_id" => nil, "task_generation" => nil
      },
      "state" => state,
      "blocker_owner" => owner,
      "reason" => reason,
      "reasons" => [ { "code" => state, "message" => reason, "source" => "task", "freshness" => "current" } ],
      "provider" => nil,
      "freshness" => { "task_observed_at" => generated_at, "scheduler_status" => "current" },
      "evidence" => { "task_action" => "ready_to_run", "condition_warning" => nil, "held" => nil },
      "action" => nil
    }
  end

  def legacy_task(project: "demo", slug: "task", action: "ready_to_run",
                  stage: nil, folder: nil, id: nil)
    stage ||= action == "archived" ? "9-done" : "4-execute"
    folder ||= "/tmp/#{project}/#{slug}"
    {
      "project" => project, "slug" => slug, "id" => id, "folder" => folder,
      "workflow" => "coding", "stage" => stage,
      "marker" => "complete", "action" => action
    }
  end

  def snapshot(*rows, archived: [])
    active = rows.compact
    legacy_rows = active.map do |row|
      legacy_task(
        project: row.dig("identity", "project"), slug: row.dig("identity", "slug"),
        id: row.dig("identity", "id"), folder: row.dig("identity", "folder"),
        stage: row.dig("position", "stage")
      )
    end + archived
    Hive::Commands::Watch::SourceSnapshot.new(
      operational: {
        "schema" => "hive-operational-status",
        "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-operational-status"),
        "ok" => true,
        "generated_at" => "2026-07-20T12:00:00Z", "completeness" => "complete",
        "source" => { "task_graph" => { "status" => "complete" } },
        "tasks" => active
      },
      full_graph: {
        "schema" => "hive-status",
        "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
        "ok" => true,
        "projects" => [ { "name" => "demo", "tasks" => legacy_rows } ]
      }
    )
  end

  def assert_watch_schema(events)
    schema = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-watch-event"))))
    events.each do |event|
      assert schema.valid?(event), schema.validate(event).map { |error| error.fetch("error") }.inspect
    end
  end
end
