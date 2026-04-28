require "test_helper"
require "json"
require "hive/cli"

# Boundary tests for the `hive tui` Thor command surface. The TUI's
# render loop and curses lifecycle are covered by `test/smoke/`; this
# file pins the help-text registration and the `--json` rejection so
# the command is discoverable and the agent-callable contract stays
# JSON-only via `hive status`.
class TuiCommandTest < Minitest::Test
  include HiveTestHelper

  def test_help_index_lists_tui
    # Thor's help index prefixes commands with `$0`; assert on the
    # subcommand-and-summary line instead of the binary name so the
    # test passes whether `bin/hive` or the test runner is at $0.
    out, _err = capture_io { Hive::CLI.start([ "help" ]) }
    assert_match(/^\s*\S+\s+tui\s+# Open the live/, out,
                 "tui command must appear in `hive help` output with its summary")
  end

  def test_help_for_tui_shows_long_description
    out, _err = capture_io { Hive::CLI.start([ "help", "tui" ]) }
    assert_match(/keystroke/, out)
    assert_match(/--json/, out, "the long description must mention the rejected --json flag")
  end

  # F22: pre-fix, `hive help tui` only listed grid bindings. Triage /
  # log_tail / filter mode bindings were only visible via `?` inside
  # the running TUI — invisible to agents that have only --help to read.
  def test_help_for_tui_lists_every_mode_keymap
    out, _err = capture_io { Hive::CLI.start([ "help", "tui" ]) }
    %w[grid triage log_tail filter].each do |mode|
      assert_match(/#{mode}/, out, "long_desc must list the '#{mode}' mode keymap")
    end
    assert_match(/Space/, out, "triage Space binding must appear in --help output")
    assert_match(/printable/, out, "filter mode editing keys must appear in --help output")
  end

  def test_json_flag_is_rejected_with_usage_exit_code
    out, err, status = with_captured_exit { Hive::CLI.start([ "tui", "--json" ]) }
    assert_equal Hive::ExitCodes::USAGE, status
    assert_match(/has no JSON output/, err)
    # The remediation pointer must surface in the prose error so a
    # human reading stderr knows where to look for the JSON contract.
    assert_match(%r{Use 'hive status --json'}, err,
                 "rejection message must point to the JSON-callable surface")

    # JSON consumers see structured error data on stdout: ok=false,
    # the same remediation prose, and the USAGE exit code so a wrapper
    # can branch without re-parsing the message.
    payload = JSON.parse(out)
    assert_equal false, payload["ok"]
    assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
    assert_match(%r{Use 'hive status --json'}, payload["message"])
    # F10: error_kind must align with other InvalidTaskPath emit sites
    # (markers/findings/run/...) which canonically use 'invalid_task_path'.
    # The TUI envelope previously used 'unsupported_flag' which forced
    # consumers to special-case the value. Normalize.
    assert_equal "invalid_task_path", payload["error_kind"],
      "TUI rejection envelope must reuse the canonical 'invalid_task_path' error_kind " \
      "so JSON consumers can switch on a single value across the CLI"
    assert_equal "InvalidTaskPath", payload["error_class"]
  end

  def test_run_without_tty_raises_clear_error_before_curses_init
    # The TUI requires a real terminal; under the test runner $stdout is a
    # StringIO. The boundary check must surface as a typed
    # Hive::InvalidTaskPath (USAGE / 64) before any Curses.init_screen
    # call so a non-tty CI invocation gets a clean exit with the same
    # exit-code contract as the `--json` rejection.
    require "hive/tui"
    err = assert_raises(Hive::InvalidTaskPath) { Hive::Tui.run }
    assert_match(/requires a terminal/, err.message)
    assert_equal Hive::ExitCodes::USAGE, err.exit_code
  end
end
