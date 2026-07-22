require "test_helper"
require "hive/commands/status"

class CommandsStatusConciseTest < Minitest::Test
  include HiveTestHelper

  class RoutingStatus < Hive::Commands::Status
    attr_reader :routes

    def initialize(**kwargs)
      super
      @routes = []
    end

    def operational_payload(_projects, **)
      @routes << :operational_payload
      {
        "completeness" => "complete",
        "summary" => { "active" => 0, "archived" => 0, "projects_total" => 1 },
        "archive" => { "count" => 0 }, "issues" => [], "tasks" => []
      }
    end

    def render_operational(_payload)
      @routes << :concise
    end

    def json_payload(_projects, **)
      @routes << :legacy_json
      { "schema" => "hive-status" }
    end

    def render_project(*, **)
      @routes << :full
    end

    def build_admission_context(*)
      {}
    end
  end

  def test_default_human_is_concise_full_is_legacy_and_json_stays_v6
    project = { "name" => "demo", "path" => "/tmp/demo", "hive_state_path" => "/tmp/demo/.hive-state" }
    with_replaced_singleton_method(Hive::Config, :registered_projects, -> { [ project ] }) do
      concise = RoutingStatus.new
      capture_io { concise.call }
      assert_equal %i[operational_payload concise], concise.routes

      full = RoutingStatus.new(full: true)
      capture_io { full.call }
      assert_equal [ :full ], full.routes

      legacy_json = RoutingStatus.new(json: true)
      capture_io { legacy_json.call }
      assert_equal [ :legacy_json ], legacy_json.routes

      operational_json = RoutingStatus.new(json: true, operational: true)
      capture_io { operational_json.call }
      assert_equal [ :operational_payload ], operational_json.routes
    end
  end

  def test_invalid_mode_combinations_are_usage_errors
    invalid = [
      { full: true, json: true },
      { full: true, operational: true },
      { full: true, diagnose: "task" },
      { operational: true, diagnose: "task" },
      { operational: true, write: true, diagnose: "task" }
    ]

    invalid.each do |kwargs|
      error = nil
      capture_io do
        error = assert_raises(Hive::InvalidTaskPath) do
          Hive::Commands::Status.new(**kwargs).call
        end
      end
      assert_match(/cannot be combined|requires/, error.message)
    end
  end

  def test_complete_renderer_caps_bands_sorts_rows_and_escapes_controls
    rows = 6.times.map do |index|
      task(
        project: index.zero? ? "a\e[2J" : "demo",
        slug: "task-#{index}", state: "running", owner: "agent",
        reason: index.zero? ? "working\nnext" : "working"
      )
    end.reverse
    payload = payload(tasks: rows, active: 6)

    out, = capture_io { Hive::Commands::Status.new.send(:render_operational, payload) }

    lines = out.lines.map(&:chomp)
    assert_equal "SNAPSHOT COMPLETE — 6 active · 0 archived", lines.first
    assert_includes out, "\\x1B"
    assert_includes out, "\\x0A"
    refute_includes out, "\e"
    assert_includes out, "+1 more — run `hive status --full`"
    assert_equal 5, lines.count { |line| line.start_with?("  ") && line.include?("task-") }
  end

  def test_empty_registry_archive_only_and_partial_never_overclaim_idle
    empty = payload(tasks: [], active: 0, archived: 0, projects_total: 0)
    archive_only = payload(tasks: [], active: 0, archived: 3, projects_total: 1)
    healthy_idle = payload(tasks: [], active: 0, archived: 0, projects_total: 1)
    partial = payload(
      completeness: "partial",
      tasks: [ task(project: "demo", slug: "ready", state: "idle", owner: "scheduler", reason: "unknown gate") ],
      active: 1,
      issues: [ issue("scheduler unavailable") ]
    )

    empty_out, = capture_io { Hive::Commands::Status.new.send(:render_operational, empty) }
    archive_out, = capture_io { Hive::Commands::Status.new.send(:render_operational, archive_only) }
    idle_out, = capture_io { Hive::Commands::Status.new.send(:render_operational, healthy_idle) }
    partial_out, = capture_io { Hive::Commands::Status.new.send(:render_operational, partial) }

    assert_match(/SNAPSHOT COMPLETE — 0 active · 0 archived/, empty_out)
    assert_match(/NO REGISTERED PROJECTS/, empty_out)
    assert_match(/hive init <path>/, empty_out)
    assert_match(/SNAPSHOT COMPLETE — 0 active · 3 archived/, archive_out)
    assert_match(/ARCHIVE ONLY/, archive_out)
    assert_match(/hive status --full/, archive_out)
    assert_match(/IDLE — no active work/, idle_out)
    assert_equal "SNAPSHOT PARTIAL — 1 active · 0 archived", partial_out.lines.first.chomp
    assert_operator partial_out.index("scheduler unavailable"), :<, partial_out.index("READY / IDLE")
    refute partial_out.lines.any? { |line| line.chomp == "IDLE" }
  end

  def test_unknown_snapshot_warns_before_content_and_never_claims_idle
    unknown = payload(
      completeness: "unknown", tasks: [], active: 0,
      issues: [ issue("task status unavailable") ]
    )

    out, = capture_io { Hive::Commands::Status.new.send(:render_operational, unknown) }

    assert_equal "SNAPSHOT UNKNOWN — 0 active · 0 archived", out.lines.first.chomp
    assert_includes out, "task status unavailable"
    refute_includes out, "IDLE"
  end

  private

  def payload(completeness: "complete", tasks:, active:, archived: 0, projects_total: 1, issues: [])
    {
      "completeness" => completeness,
      "summary" => {
        "active" => active, "archived" => archived, "projects_total" => projects_total
      },
      "archive" => { "count" => archived },
      "issues" => issues,
      "tasks" => tasks
    }
  end

  def task(project:, slug:, state:, owner:, reason:)
    {
      "identity" => { "project" => project, "slug" => slug, "display_name" => slug },
      "position" => { "stage" => "4-execute", "marker" => "agent_working" },
      "state" => state, "blocker_owner" => owner, "reason" => reason
    }
  end

  def issue(message)
    { "message" => message, "remediation" => "wait for a complete daemon tick" }
  end
end
