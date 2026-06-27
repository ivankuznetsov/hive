require "test_helper"
require "hive/tui/state_source"
require "support/tui_scale_fixture"

class TuiReactivityPerfTest < Minitest::Test
  include HiveTestHelper

  PROJECTS = 8
  ACTIVE_TOTAL = 8
  SMALL_TASKS_PER_PROJECT = 10
  LARGE_TASKS_PER_PROJECT = 200
  IDLE_TICK_BUDGET_MS = 5.0
  # Tuned after the U1/U3 profile on this checkout: active-only parse is
  # the correctness fallback path, while archive-size independence is
  # the primary regression signal this test enforces.
  ACTIVE_REPARSE_BUDGET_MS = 100.0
  # Coverage instrumentation materially changes wall-clock parse cost, so keep
  # the normal test-suite budget strict and use this only for `rake coverage`.
  COVERAGE_ACTIVE_REPARSE_BUDGET_MS = 150.0
  IDLE_SCALING_TOLERANCE = 3.0
  IDLE_SCALING_ADD_MS = 1.0
  ACTIVE_SCALING_TOLERANCE = 2.0
  ACTIVE_SCALING_ADD_MS = 20.0

  def test_idle_tick_and_active_parse_stay_within_scale_budgets
    small = measure_fixture(tasks_per_project: SMALL_TASKS_PER_PROJECT)
    large = measure_fixture(tasks_per_project: LARGE_TASKS_PER_PROJECT)

    # Gate the parseability invariant in CI (previously only asserted behind
    # HIVE_TUI_PROFILE=1): every fixture task must materialize into a row, so
    # a regression that silently drops rows fails here, not just under the
    # opt-in profile.
    assert_equal PROJECTS * LARGE_TASKS_PER_PROJECT, large.fetch(:rows),
                 "all #{PROJECTS}x#{LARGE_TASKS_PER_PROJECT} tasks must parse into rows"
    assert_operator large.fetch(:idle_tick_ms), :<, IDLE_TICK_BUDGET_MS,
                    "idle tick should stay below #{IDLE_TICK_BUDGET_MS}ms at 8x200"
    assert_operator large.fetch(:active_parse_ms), :<, active_reparse_budget_ms,
                    "active parse should stay below #{active_reparse_budget_ms}ms at 8x200"
    assert_scaled(
      small.fetch(:idle_tick_ms),
      large.fetch(:idle_tick_ms),
      tolerance: IDLE_SCALING_TOLERANCE,
      additive_ms: IDLE_SCALING_ADD_MS,
      label: "idle tick"
    )
    assert_scaled(
      small.fetch(:active_parse_ms),
      large.fetch(:active_parse_ms),
      tolerance: ACTIVE_SCALING_TOLERANCE,
      additive_ms: ACTIVE_SCALING_ADD_MS,
      label: "active parse"
    )
  end

  private

  def active_reparse_budget_ms
    ENV["HIVE_COVERAGE"] ? COVERAGE_ACTIVE_REPARSE_BUDGET_MS : ACTIVE_REPARSE_BUDGET_MS
  end

  def measure_fixture(tasks_per_project:)
    with_tmp_global_config do |home|
      projects = HiveTuiScaleFixture.build(
        root: File.join(home, "projects"),
        projects: PROJECTS,
        tasks_per_project: tasks_per_project,
        active_count: ACTIVE_TOTAL
      )
      source = Hive::Tui::StateSource.new(poll_interval_seconds: 60)
      source.send(:refresh_once)
      {
        rows: source.current.rows.size,
        idle_tick_ms: min_ms { source.send(:refresh_once) },
        active_parse_ms: min_ms { force_active_reparse(source) }
      }
    ensure
      source&.stop
    end
  end

  def force_active_reparse(source)
    source.instance_variable_set(
      :@last_full_parse_at,
      Time.now - (Hive::Tui::StateSource::LIVENESS_REPARSE_FALLBACK_SECONDS + 1.0)
    )
    source.send(:refresh_once)
  end

  def min_ms(samples: 5, warmups: 2)
    warmups.times { yield }
    Array.new(samples) do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
    end.min
  end

  def assert_scaled(small_ms, large_ms, tolerance:, additive_ms:, label:)
    ceiling = [ small_ms * tolerance, small_ms + additive_ms ].max
    assert_operator large_ms, :<=, ceiling,
                    "#{label} grew with archive size: small=#{format('%.2f', small_ms)}ms " \
                    "large=#{format('%.2f', large_ms)}ms ceiling=#{format('%.2f', ceiling)}ms"
  end
end
