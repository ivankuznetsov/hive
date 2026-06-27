require "test_helper"
require "hive/tui/state_source"
require "support/tui_scale_fixture"

class TuiReactivityProfileTest < Minitest::Test
  include HiveTestHelper

  PROJECTS = 8
  TASKS_PER_PROJECT = 200
  ACTIVE_PER_PROJECT = 8

  def test_scale_fixture_is_parseable_and_profiled
    with_tmp_global_config do |home|
      projects = HiveTuiScaleFixture.build(
        root: File.join(home, "projects"),
        projects: PROJECTS,
        tasks_per_project: TASKS_PER_PROJECT,
        active_count: ACTIVE_PER_PROJECT
      )

      payload = Hive::Commands::Status.new.json_payload(projects)
      parsed_task_count = payload.fetch("projects").sum { |project| project.fetch("tasks").size }
      assert_equal PROJECTS * TASKS_PER_PROJECT, parsed_task_count

      source = Hive::Tui::StateSource.new(poll_interval_seconds: 60)
      source.send(:refresh_once)
      assert_equal PROJECTS * TASKS_PER_PROJECT, source.current.rows.size

      fingerprint_seconds = median_seconds { source.send(:mtime_fingerprint_unchanged?) }
      full_parse_seconds = median_seconds { Hive::Commands::Status.new.json_payload(projects) }
      active_parse_seconds = active_parse_supported? ? median_seconds { active_payload(projects) } : nil

      puts format(
        "tui profile fixture=%<projects>dx%<tasks>d active_total=%<active>d " \
        "fingerprint_ms=%<fingerprint>.2f full_parse_ms=%<full>.2f active_parse_ms=%<active_ms>s",
        projects: PROJECTS,
        tasks: TASKS_PER_PROJECT,
        active: ACTIVE_PER_PROJECT,
        fingerprint: fingerprint_seconds * 1000,
        full: full_parse_seconds * 1000,
        active_ms: active_parse_seconds ? format("%.2f", active_parse_seconds * 1000) : "n/a"
      )
    end
  end

  private

  def median_seconds(samples: 3)
    Array.new(samples) do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    end.sort.fetch(samples / 2)
  end

  def active_parse_supported?
    Hive::Commands::Status.instance_method(:json_payload).parameters.any? do |kind, name|
      kind == :key && name == :stages
    end
  end

  def active_payload(projects)
    Hive::Commands::Status.new.json_payload(
      projects,
      stages: HiveTuiScaleFixture::ACTIVE_STAGES
    )
  end
end
