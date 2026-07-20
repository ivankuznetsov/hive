require "test_helper"
require "json"
require "json_schemer"
require "stringio"
require "hive/commands/digest"
require "hive/commands/watch"

class CommandsWatchTest < Minitest::Test
  include HiveTestHelper

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

  private

  def build_watch(source:, targets:, output:, clock: FakeClock.new, project: nil,
                  until_condition: "settled", timeout: 30, max_events: 100,
                  interval: 1, json_lines: true, json: false, signal_checker: -> { nil })
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
      sleeper: ->(seconds) { clock.advance(seconds) },
      output: output,
      signal_checker: signal_checker
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
           reason: "ready", generated_at: "2026-07-20T12:00:00Z")
    {
      "identity" => {
        "project" => project, "slug" => slug, "id" => nil,
        "display_name" => slug, "folder" => "/tmp/#{project}/#{slug}"
      },
      "workflow" => "coding",
      "position" => { "stage" => "4-execute", "marker" => "waiting" },
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

  def legacy_task(project: "demo", slug: "task", action: "ready_to_run")
    {
      "project" => project, "slug" => slug, "folder" => "/tmp/#{project}/#{slug}",
      "workflow" => "coding", "stage" => action == "archived" ? "9-done" : "4-execute",
      "marker" => "complete", "action" => action
    }
  end

  def snapshot(*rows, archived: [])
    active = rows.compact
    legacy_rows = active.map do |row|
      legacy_task(
        project: row.dig("identity", "project"), slug: row.dig("identity", "slug")
      )
    end + archived
    Hive::Commands::Watch::SourceSnapshot.new(
      operational: {
        "schema" => "hive-operational-status", "schema_version" => 1, "ok" => true,
        "generated_at" => "2026-07-20T12:00:00Z", "completeness" => "complete",
        "source" => { "task_graph" => { "status" => "complete" } },
        "tasks" => active
      },
      full_graph: {
        "schema" => "hive-status", "schema_version" => 6, "ok" => true,
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
