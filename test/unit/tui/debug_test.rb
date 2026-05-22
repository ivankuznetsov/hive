require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "hive/tui/debug"

class HiveTuiDebugTest < Minitest::Test
  include HiveTestHelper

  def test_disabled_debug_is_noop_but_around_returns_block_value
    assert_nil Hive::Tui::Debug.log_path
    assert_nil Hive::Tui::Debug.log("noop", "message")
    assert_equal 42, Hive::Tui::Debug.around("noop") { 42 }
  end

  def test_format_line_omits_blank_message_and_includes_nonblank_message
    blank = Hive::Tui::Debug.format_line("tag", "")
    with_message = Hive::Tui::Debug.format_line("tag", "detail")

    assert_match(/\A\d{2}:\d{2}:\d{2}\.\d{3} \[tag\]\z/, blank)
    assert_match(/\A\d{2}:\d{2}:\d{2}\.\d{3} \[tag\] detail\z/, with_message)
  end

  def test_enabled_debug_writes_session_log_and_wraps_success_and_error
    with_tmp_dir do |dir|
      script = <<~'RUBY'
        require "json"
        require "hive/tui/debug"

        Hive::Tui::Debug.log("plain")
        Hive::Tui::Debug.log("message", "detail")
        returned = Hive::Tui::Debug.around("wrap", "work") { "done" }
        raised = begin
          Hive::Tui::Debug.around("wrap", "boom") { raise ArgumentError, "bad" }
        rescue ArgumentError => e
          "#{e.class}: #{e.message}"
        end

        puts JSON.generate(
          path: Hive::Tui::Debug.log_path,
          returned: returned,
          raised: raised,
          lines: File.readlines(Hive::Tui::Debug.log_path, chomp: true)
        )
      RUBY

      env = {
        "HIVE_TUI_DEBUG" => "1",
        "TMPDIR" => dir,
        "HIVE_COVERAGE" => ENV["HIVE_COVERAGE"],
        "HIVE_COVERAGE_ROOT" => ENV["HIVE_COVERAGE_ROOT"],
        "RUBYOPT" => ENV["RUBYOPT"]
      }.compact
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-Ilib", "-e", script)

      assert status.success?, err
      payload = JSON.parse(out)
      assert_equal File.join(dir, "hive-tui-debug.log"), payload.fetch("path")
      assert_equal "done", payload.fetch("returned")
      assert_equal "ArgumentError: bad", payload.fetch("raised")

      lines = payload.fetch("lines")
      assert_match(/\A=== hive tui debug session pid=\d+ started /, lines.fetch(0))
      assert_match(/\[plain\]\z/, lines.fetch(1))
      assert_match(/\[message\] detail\z/, lines.fetch(2))
      assert_match(/\[wrap\] enter work\z/, lines.fetch(3))
      assert_match(/\[wrap\] exit  work -> "done"\z/, lines.fetch(4))
      assert_match(/\[wrap\] enter boom\z/, lines.fetch(5))
      assert_match(/\[wrap\] raise boom -> ArgumentError: bad\z/, lines.fetch(6))
    end
  end
end
