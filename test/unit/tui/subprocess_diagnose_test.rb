require "test_helper"
require "tmpdir"
require "hive/tui/subprocess"

# Direct unit tests for `Subprocess.diagnose_recent_failure` and its
# parsing helpers. Pre-existing coverage exercised this only through
# `BubbleModel#diagnose_subprocess_exit` (two cases: happy path +
# fall-through). The parser branches — empty log, no BEGIN, missing
# END, 64KB cap, concurrent verb interleaving, interactive-variant
# stamps — needed direct coverage so a regression in
# `recent_log_section_for` / `parse_argv_from_section` /
# `extract_project` surfaces immediately rather than hiding behind
# the BubbleModel wrapper.
class HiveTuiSubprocessDiagnoseTest < Minitest::Test
  include HiveTestHelper

  def with_isolated_log
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hive-tui-subprocess.log")
      original = Hive::Tui::Subprocess::SUBPROCESS_LOG_PATH
      Hive::Tui::Subprocess.send(:remove_const, :SUBPROCESS_LOG_PATH)
      Hive::Tui::Subprocess.const_set(:SUBPROCESS_LOG_PATH, path)
      begin
        yield path
      ensure
        Hive::Tui::Subprocess.send(:remove_const, :SUBPROCESS_LOG_PATH)
        Hive::Tui::Subprocess.const_set(:SUBPROCESS_LOG_PATH, original)
      end
    end
  end

  def write_section(path, argv:, stderr:, exit_code:, label: nil)
    label ||= "" # "" or "(interactive)"
    File.open(path, "a") do |f|
      f.puts "----- 2026-04-28T11:00:00Z BEGIN#{label}: #{argv.join(' ')} -----"
      f.puts stderr
      f.puts "----- 2026-04-28T11:00:01Z END#{label} exit=#{exit_code}: #{argv.join(' ')} -----"
    end
  end

  # ---- Empty / missing-file branches ----

  def test_returns_nil_when_log_file_does_not_exist
    with_isolated_log do |path|
      File.delete(path) if File.exist?(path)
      assert_nil Hive::Tui::Subprocess.diagnose_recent_failure("pr"),
        "missing log → nil (caller falls back to default flash)"
    end
  end

  def test_returns_nil_when_log_file_is_empty
    with_isolated_log do
      assert_nil Hive::Tui::Subprocess.diagnose_recent_failure("pr"),
        "empty log → nil"
    end
  end

  def test_returns_nil_when_no_begin_for_verb
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive develop slug --project p],
        stderr: "some output", exit_code: 1)
      assert_nil Hive::Tui::Subprocess.diagnose_recent_failure("pr"),
        "no BEGIN for the asked verb → nil"
    end
  end

  # ---- Pattern matching ----

  def test_missing_origin_remote_pattern
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive pr slug --project demo --from 5-review],
        stderr: "fatal: 'origin' does not appear to be a git repository",
        exit_code: 1)
      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/demo:.*project not set up/i, result,
        "names the project + says project not set up — matches the dogfood-driven UX requirement")
    end
  end

  def test_could_not_read_from_remote_pattern
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive pr slug --project myproj],
        stderr: "Could not read from remote repository.",
        exit_code: 1)
      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/myproj/, result)
      assert_match(/project not set up|origin/i, result)
    end
  end

  def test_gh_command_not_found_pattern
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive pr slug --project p],
        stderr: "/bin/sh: gh: command not found",
        exit_code: 1)
      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/gh.*not installed/i, result)
    end
  end

  def test_ssh_permission_denied_pattern
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive pr slug --project p],
        stderr: "git@github.com: Permission denied (publickey).",
        exit_code: 1)
      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/git auth failed/i, result)
      assert_match(/SSH key|gh auth/i, result)
    end
  end

  def test_unknown_failure_returns_nil_for_default_flash_fallback
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive pr slug --project p],
        stderr: "totally novel error nobody has a pattern for",
        exit_code: 1)
      assert_nil Hive::Tui::Subprocess.diagnose_recent_failure("pr"),
        "unrecognized stderr → nil (caller shows generic exit-code flash)"
    end
  end

  # ---- Interactive-stamp variant ----

  def test_diagnoses_interactive_variant_section_after_regex_broadening
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive pr slug --project demo],
        stderr: "fatal: 'origin' does not appear to be a git repository",
        exit_code: 1,
        label: "(interactive)")
      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      refute_nil result,
        "regex must match BEGIN(interactive): / END(interactive) exit= so future " \
        "interactive verbs benefit from the same diagnostic flashes"
      assert_match(/demo:.*project not set up/i, result)
    end
  end

  # ---- Edge cases: missing END / multiple sections / capped tail ----

  def test_section_without_end_marker_still_matches
    with_isolated_log do |path|
      File.open(path, "a") do |f|
        f.puts "----- 2026-04-28T11:00:00Z BEGIN: hive pr slug --project p -----"
        f.puts "fatal: 'origin' does not appear to be a git repository"
        # No END line — verb still running or supervisor crashed mid-write
      end
      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      refute_nil result,
        "section without an END line is still diagnosable up to EOF"
    end
  end

  def test_picks_most_recent_section_when_multiple_present_for_same_verb
    with_isolated_log do |path|
      write_section(path,
        argv: %w[hive pr slug --project old],
        stderr: "fatal: 'origin' does not appear to be a git repository",
        exit_code: 1)
      write_section(path,
        argv: %w[hive pr slug --project new],
        stderr: "Permission denied (publickey)",
        exit_code: 1)
      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/git auth failed/i, result,
        "must use the most recent matching section; older sections are stale")
      refute_match(/old:/, result, "must NOT use the older section's --project value")
    end
  end

  def test_returns_nil_when_begin_outside_64kb_tail_cap
    with_isolated_log do |path|
      # Push the BEGIN past the 64KB read window.
      File.open(path, "a") do |f|
        f.puts "----- 2026-04-28T10:00:00Z BEGIN: hive pr slug --project p -----"
        f.puts "fatal: 'origin' does not appear to be a git repository"
        f.puts "----- 2026-04-28T10:00:01Z END exit=1: hive pr slug --project p -----"
        f.puts "junk line\n" * 10_000 # > 64KB of unrelated content after the BEGIN
      end
      assert_nil Hive::Tui::Subprocess.diagnose_recent_failure("pr"),
        "out-of-cap BEGIN must return nil rather than crash on a partial scan"
    end
  end

  # ---- extract_project edge cases ----

  def test_extract_project_pulls_value_after_project_flag
    assert_equal "demo",
      Hive::Tui::Subprocess.send(:extract_project,
        %w[hive pr slug --project demo --from 5-review])
  end

  def test_extract_project_returns_nil_when_flag_absent
    assert_nil Hive::Tui::Subprocess.send(:extract_project, %w[hive pr slug])
  end

  def test_extract_project_returns_nil_when_flag_at_argv_end_with_no_value
    # `--project` is the last argv element with no value following.
    assert_nil Hive::Tui::Subprocess.send(:extract_project, %w[hive pr slug --project]),
      "trailing --project with no value must not raise (returns nil)"
  end
end
