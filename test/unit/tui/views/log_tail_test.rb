require "test_helper"
require "hive/tui/model"
require "hive/tui/views/log_tail"

# Layout assertions for `Views::LogTail.render(model)`. The view reads
# `model.tail_state` for `path`, `claude_pid_alive`, and `lines(n)`.
# In tests we use a tiny double rather than a real `LogTail::Tail`
# so the assertions stay independent of file I/O.
class HiveTuiViewsLogTailTest < Minitest::Test
  include HiveTestHelper

  TailDouble = Struct.new(:path, :claude_pid_alive, :buffer) do
    def lines(count)
      buffer.last(count)
    end
  end

  def base_model(tail_state:, **overrides)
    Hive::Tui::Model.initial.with(mode: :log_tail, tail_state: tail_state, cols: 80, rows: 12, **overrides)
  end

  # ---- Empty state ----

  def test_returns_empty_when_tail_state_nil
    model = Hive::Tui::Model.initial.with(tail_state: nil, mode: :log_tail)
    assert_equal "", Hive::Tui::Views::LogTail.render(model)
  end

  # ---- Header ----

  def test_top_line_is_log_path
    tail = TailDouble.new("/path/to/.hive/logs/agent.log", true, [])
    out = Hive::Tui::Views::LogTail.render(base_model(tail_state: tail))
    assert_match(%r{^.*/path/to/\.hive/logs/agent\.log}, out.lines.first.to_s)
  end

  def test_long_path_is_truncated_to_terminal_width
    long_path = "x" * 200
    tail = TailDouble.new(long_path, true, [])
    out = Hive::Tui::Views::LogTail.render(base_model(tail_state: tail, cols: 40))
    first_line = out.lines.first.to_s.chomp
    assert first_line.length <= 40,
      "long path must be truncated to fit terminal width, got #{first_line.length}: #{first_line.inspect}"
  end

  # ---- Body ----

  def test_body_shows_trailing_lines_up_to_available_height
    buffer = (1..30).map { |i| "line-#{i}" }
    tail = TailDouble.new("/log", true, buffer)
    out = Hive::Tui::Views::LogTail.render(base_model(tail_state: tail, rows: 12))
    # 12 rows = 1 path + 1 footer + 10 body lines
    assert_includes out, "line-30"
    assert_includes out, "line-21"
    refute_includes out, "line-20", "older lines beyond available height must not render"
  end

  def test_body_short_log_pads_to_keep_footer_anchored
    tail = TailDouble.new("/log", true, [ "only-line" ])
    out = Hive::Tui::Views::LogTail.render(base_model(tail_state: tail, rows: 12))
    # Footer should still be the last line — pad lines hold the position.
    last_nonempty = out.lines.reject { |l| l.strip.empty? }.last.to_s
    assert_includes last_nonempty, "[q] back to grid"
  end

  # ---- Footer ----

  def test_footer_shows_back_hint
    tail = TailDouble.new("/log", true, [ "x" ])
    out = Hive::Tui::Views::LogTail.render(base_model(tail_state: tail))
    assert_includes out, "[q] back to grid"
  end

  def test_footer_appends_stale_annotation_when_pid_not_alive
    tail = TailDouble.new("/log", false, [ "x" ])
    out = Hive::Tui::Views::LogTail.render(base_model(tail_state: tail))
    assert_includes out, "[stale: claude_pid no longer alive]"
  end

  def test_footer_omits_stale_when_pid_unknown
    tail = TailDouble.new("/log", nil, [ "x" ])
    out = Hive::Tui::Views::LogTail.render(base_model(tail_state: tail))
    refute_includes out, "stale", "nil pid_alive must not flag stale (only false does)"
  end
end
