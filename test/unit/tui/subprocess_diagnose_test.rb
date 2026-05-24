require "test_helper"
require "rbconfig"
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
        argv: %w[hive pr slug --project demo --from 6-review],
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

  # ---- F25: pre-write rotation caps SUBPROCESS_LOG_PATH growth ----

  def test_stamp_subprocess_log_rotates_when_size_exceeds_threshold
    with_isolated_log do |path|
      # Pre-fill the log past the threshold with arbitrary bytes — content
      # doesn't matter, only File.size?.
      threshold = Hive::Tui::Subprocess::SUBPROCESS_LOG_MAX_BYTES
      File.write(path, "x" * (threshold + 1))
      assert File.size(path) > threshold, "fixture sanity: log starts oversized"

      Hive::Tui::Subprocess.send(:stamp_subprocess_log, "BEGIN", %w[hive pr slug])

      rotated = "#{path}.1"
      assert File.exist?(rotated), "oversized log must be renamed to <path>.1"
      assert File.exist?(path), "stamp_subprocess_log must recreate the primary log"
      assert File.size(path) < threshold,
        "primary log starts fresh after rotation (only the new BEGIN marker)"
    end
  end

  def test_stamp_subprocess_log_does_not_rotate_within_threshold
    with_isolated_log do |path|
      File.write(path, "small payload\n")
      original_size = File.size(path)

      Hive::Tui::Subprocess.send(:stamp_subprocess_log, "BEGIN", %w[hive pr slug])

      rotated = "#{path}.1"
      refute File.exist?(rotated), "below the threshold no rotation must occur"
      assert File.size(path) > original_size, "stamp must still append to the primary log"
    end
  end

  def test_stamp_subprocess_log_overwrites_existing_rotated_copy
    with_isolated_log do |path|
      threshold = Hive::Tui::Subprocess::SUBPROCESS_LOG_MAX_BYTES
      File.write("#{path}.1", "OLDCONTENT")
      File.write(path, "x" * (threshold + 1))

      Hive::Tui::Subprocess.send(:stamp_subprocess_log, "BEGIN", %w[hive pr slug])

      rotated_content = File.read("#{path}.1")
      refute_match(/OLDCONTENT/, rotated_content,
        "single-tier rotation: rename overwrites the prior .1; total disk usage stays bounded")
      assert rotated_content.start_with?("x"),
        "rotated content must be the freshly oversized log, not the old .1"
    end
  end

  # ---- F7: per-spawn correlation IDs prevent verb section cross-talk ----

  def test_interleaved_concurrent_verbs_use_correlation_ids_to_pair_begin_end
    # Two verbs running concurrently interleave their BEGIN/END markers
    # at line boundaries. Pre-F7 the parser walked "last BEGIN for verb"
    # then "next END (any verb)" and would pick up the OTHER verb's END,
    # capturing a stderr block that wasn't the right one. With F7, the
    # `[ID]` correlation tokens on BEGIN[ID] / END[ID] let the parser
    # pair them correctly even under interleave.
    with_isolated_log do |path|
      File.open(path, "a") do |f|
        f.puts "----- 2026-04-28T11:00:00Z BEGIN[aaaaaaaa]: hive pr slug --project demo-pr -----"
        f.puts "----- 2026-04-28T11:00:00Z BEGIN[bbbbbbbb]: hive develop slug --project demo-dev -----"
        # The DEVELOP child writes its stderr first
        f.puts "totally novel develop output"
        f.puts "----- 2026-04-28T11:00:01Z END[bbbbbbbb] exit=2: hive develop slug --project demo-dev -----"
        # Then PR's stderr
        f.puts "fatal: 'origin' does not appear to be a git repository"
        f.puts "----- 2026-04-28T11:00:02Z END[aaaaaaaa] exit=1: hive pr slug --project demo-pr -----"
      end

      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/demo-pr:.*project not set up/i, result,
        "PR diagnostic must scope to the [aaaaaaaa] section's content; pre-F7 this " \
        "would terminate at the END[bbbbbbbb] line and miss PR's actual stderr")
    end
  end

  def test_correlation_id_section_does_not_leak_into_subsequent_verbs
    # The opposite direction: PR's section ends BEFORE develop's stderr
    # arrives. Diagnose for develop must not roll backward into PR's
    # stderr.
    with_isolated_log do |path|
      File.open(path, "a") do |f|
        f.puts "----- 2026-04-28T11:00:00Z BEGIN[aaaaaaaa]: hive pr slug --project alpha -----"
        f.puts "Permission denied (publickey)."
        f.puts "----- 2026-04-28T11:00:01Z END[aaaaaaaa] exit=1: hive pr slug --project alpha -----"
        f.puts "----- 2026-04-28T11:00:02Z BEGIN[cccccccc]: hive develop slug --project alpha -----"
        f.puts "totally novel error"
        f.puts "----- 2026-04-28T11:00:03Z END[cccccccc] exit=1: hive develop slug --project alpha -----"
      end

      assert_nil Hive::Tui::Subprocess.diagnose_recent_failure("develop"),
        "develop section is the [cccccccc] block; its stderr is unmatched, must return nil " \
        "rather than reach back into PR's [aaaaaaaa] block"
    end
  end

  def test_legacy_id_less_entries_still_match_via_fallback
    # Logs written before F7 have no [ID]. Mixed shape: the BEGIN line
    # has no [ID] (legacy), and the END line has no [ID] either. Parser
    # falls back to "first END after BEGIN".
    with_isolated_log do |path|
      File.open(path, "a") do |f|
        f.puts "----- 2026-04-28T11:00:00Z BEGIN: hive pr slug --project legacy -----"
        f.puts "fatal: 'origin' does not appear to be a git repository"
        f.puts "----- 2026-04-28T11:00:01Z END exit=1: hive pr slug --project legacy -----"
      end

      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/legacy:.*project not set up/i, result,
        "legacy log entries (no [ID]) must keep working — first-END-after-BEGIN fallback")
    end
  end

  def test_real_stamp_subprocess_log_emits_correlation_ids_when_id_supplied
    with_isolated_log do |path|
      Hive::Tui::Subprocess.send(:stamp_subprocess_log, "BEGIN", %w[hive pr slug], id: "deadbeef")
      Hive::Tui::Subprocess.send(:stamp_subprocess_log, "END exit=0", %w[hive pr slug], id: "deadbeef")
      content = File.read(path)
      assert_match(/BEGIN\[deadbeef\]:/, content,
        "stamp_subprocess_log with id: must embed [ID] in the BEGIN label")
      assert_match(/END\[deadbeef\] exit=0:/, content,
        "stamp_subprocess_log with id: must embed [ID] BEFORE the exit= suffix on END labels")
    end
  end

  def test_real_stamp_subprocess_log_keeps_legacy_shape_without_id
    with_isolated_log do |path|
      Hive::Tui::Subprocess.send(:stamp_subprocess_log, "BEGIN", %w[hive pr slug])
      content = File.read(path)
      assert_match(/BEGIN: hive pr slug/, content,
        "no id: → no [ID] section, legacy stamp shape preserved"
      )
      refute_match(/BEGIN\[/, content)
    end
  end

  # Diagnose flow over per-spawn capture: pre-fix, recent_log_section_for
  # returned only the capture body so parse_argv_from_section ran against
  # stderr and lost `--project`. The diagnostic flash dropped the project
  # name. The fix prepends the BEGIN line so argv is recoverable.
  def test_per_spawn_diagnose_keeps_project_in_flash
    with_isolated_log do |path|
      # Marker entry with a per-spawn ID (no embedded stderr — that lives
      # in the per-spawn capture file).
      File.open(path, "a") do |f|
        f.puts "----- 2026-04-29T10:00:00Z BEGIN[deadbeef]: hive pr slug --project demo-pr -----"
        f.puts "----- 2026-04-29T10:00:01Z END[deadbeef] exit=1: hive pr slug --project demo-pr -----"
      end

      # Per-spawn capture file holds the actual stderr.
      capture_path = File.join(Dir.tmpdir, "hive-tui-spawn-deadbeef.log")
      File.write(capture_path, "fatal: 'origin' does not appear to be a git repository\n")

      result = Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      assert_match(/demo-pr:.*project not set up/i, result,
        "diagnose must extract --project from the BEGIN line even when stderr lives in a per-spawn file"
      )
    ensure
      File.delete(capture_path) if capture_path && File.exist?(capture_path)
    end
  end

  def test_bound_spawn_capture_truncates_retained_failure_file
    spawn_id = "feedbeef"
    capture_path = File.join(Dir.tmpdir, "hive-tui-spawn-#{spawn_id}.log")
    File.write(capture_path, "x" * (Hive::Tui::Subprocess::SPAWN_CAPTURE_MAX_BYTES + 10))

    Hive::Tui::Subprocess.send(:bound_spawn_capture, spawn_id)

    assert File.size(capture_path) < Hive::Tui::Subprocess::SPAWN_CAPTURE_MAX_BYTES + 10
    assert_includes File.read(capture_path, 128), "truncated to last"
  ensure
    File.delete(capture_path) if capture_path && File.exist?(capture_path)
  end

  def test_bounded_capture3_times_out_and_reaps_process_group
    error = assert_raises(Hive::Tui::Subprocess::TimeoutError) do
      Hive::Tui::Subprocess.send(:bounded_capture3, RbConfig.ruby, "-e", "sleep 5", timeout: 0.1)
    end

    assert_operator error.elapsed, :>=, 0.1
  end

  # ---- extract_project edge cases ----

  def test_extract_project_pulls_value_after_project_flag
    assert_equal "demo",
      Hive::Tui::Subprocess.send(:extract_project,
        %w[hive pr slug --project demo --from 6-review])
  end

  def test_extract_project_returns_nil_when_flag_absent
    assert_nil Hive::Tui::Subprocess.send(:extract_project, %w[hive pr slug])
  end

  def test_extract_project_returns_nil_when_flag_at_argv_end_with_no_value
    # `--project` is the last argv element with no value following.
    assert_nil Hive::Tui::Subprocess.send(:extract_project, %w[hive pr slug --project]),
      "trailing --project with no value must not raise (returns nil)"
  end

  # ---- helper edge cases ------------------------------------------------

  def test_log_dir_and_path_use_env_override
    old = ENV["HIVE_TUI_LOG_DIR"]
    Dir.mktmpdir do |dir|
      ENV["HIVE_TUI_LOG_DIR"] = dir

      assert_equal dir, Hive::Tui::Subprocess.send(:log_dir)
      assert_equal File.join(dir, "hive-tui-subprocess.log"), Hive::Tui::Subprocess.log_path
    end
  ensure
    old.nil? ? ENV.delete("HIVE_TUI_LOG_DIR") : ENV["HIVE_TUI_LOG_DIR"] = old
  end

  def test_spawn_reaper_thread_logs_wait_and_dispatch_failures
    logs = []
    dispatch = ->(_msg) { raise "runner gone" }

    with_replaced_singleton_method(Process, :wait2, ->(_pid) { raise Errno::ECHILD }) do
      with_replaced_singleton_method(Hive::Tui::Debug, :log, ->(*args) { logs << args }) do
        thread = Hive::Tui::Subprocess.spawn_reaper_thread(12_345, "pr", %w[hive pr slug], dispatch, "deadbeef")
        thread.join(1)
        refute thread.alive?
      end
    end

    assert logs.any? { |scope, message| scope == "dispatch_background" && message.include?("reaper:") }
    assert logs.any? { |scope, message| scope == "dispatch_background" && message.include?("reaper-dispatch") }
  end

  def test_delete_spawn_capture_tolerates_missing_and_logs_other_errors
    with_log_dir do
      assert_nil Hive::Tui::Subprocess.send(:delete_spawn_capture, "missing1")

      with_replaced_singleton_method(File, :delete, ->(_path) { raise Errno::EACCES }) do
        assert_nil Hive::Tui::Subprocess.send(:delete_spawn_capture, "missing2")
      end
    end
  end

  def test_sweep_old_spawn_captures_tolerates_deleted_files_and_glob_failures
    with_log_dir do |dir|
      orphan = File.join(dir, "hive-tui-spawn-deadbeef.log")
      File.write(orphan, "old")
      File.utime(Time.now - (25 * 60 * 60), Time.now - (25 * 60 * 60), orphan)

      with_replaced_singleton_method(File, :delete, ->(_path) { raise Errno::ENOENT }) do
        Hive::Tui::Subprocess.send(:sweep_old_spawn_captures!)
      end

      with_replaced_singleton_method(Dir, :glob, ->(_pattern) { raise "glob failed" }) do
        assert_nil Hive::Tui::Subprocess.send(:sweep_old_spawn_captures!)
      end
    end
  end

  def test_bound_spawn_capture_noops_missing_files_and_logs_failures
    with_log_dir do
      assert_nil Hive::Tui::Subprocess.send(:bound_spawn_capture, "missing")

      spawn_id = "feedbeef"
      path = Hive::Tui::Subprocess.spawn_capture_path(spawn_id)
      File.write(path, "x" * (Hive::Tui::Subprocess::SPAWN_CAPTURE_MAX_BYTES + 1))
      original_size = File.method(:size)

      with_replaced_singleton_method(File, :size, lambda { |candidate|
        raise "size unavailable" if candidate == path

        original_size.call(candidate)
      }) do
        assert_nil Hive::Tui::Subprocess.send(:bound_spawn_capture, spawn_id)
      end
    end
  end

  def test_stamp_subprocess_log_tolerates_write_failures
    with_log_dir do
      with_replaced_singleton_method(FileUtils, :mkdir_p, ->(_path) { raise Errno::EACCES }) do
        assert_nil Hive::Tui::Subprocess.send(:stamp_subprocess_log, "BEGIN", %w[hive pr slug])
      end
    end
  end

  def test_rotate_subprocess_log_tolerates_permission_errors
    with_log_dir do
      path = Hive::Tui::Subprocess.log_path
      File.write(path, "x" * (Hive::Tui::Subprocess::SUBPROCESS_LOG_MAX_BYTES + 1))

      with_replaced_singleton_method(File, :rename, ->(_from, _to) { raise Errno::EACCES }) do
        assert_nil Hive::Tui::Subprocess.send(:rotate_subprocess_log_if_needed)
      end
    end
  end

  def test_annotate_label_with_id_leaves_unpaired_labels_unchanged
    assert_equal "ERRNO Errno::ENOENT",
      Hive::Tui::Subprocess.send(:annotate_label_with_id, "ERRNO Errno::ENOENT", "deadbeef")
  end

  def test_diagnose_recent_failure_logs_and_returns_nil_on_parser_error
    with_isolated_log do |path|
      File.write(path, "placeholder\n")

      with_replaced_singleton_method(Hive::Tui::Subprocess, :recent_log_section_for, ->(_verb) { raise "parse boom" }) do
        assert_nil Hive::Tui::Subprocess.diagnose_recent_failure("pr")
      end
    end
  end

  def test_read_spawn_capture_returns_nil_when_file_disappears
    assert_nil Hive::Tui::Subprocess.send(:read_spawn_capture, "deadbeef", 1024)
  end

  def test_run_quiet_returns_timeout_sentinel_and_partial_output
    error = Hive::Tui::Subprocess::TimeoutError.new(stdout: "partial out", stderr: "partial err", elapsed: 1.25)

    with_replaced_singleton_method(Hive::Tui::Subprocess, :bounded_capture3, ->(*_cmd, timeout:) { raise error }) do
      exit_code, out, err = Hive::Tui::Subprocess.run_quiet!(%w[hive status])

      assert_equal Hive::Tui::Subprocess::COMMAND_TIMEOUT_EXIT, exit_code
      assert_equal "partial out", out
      assert_includes err, "command timed out after 1.25s"
      assert_includes err, "partial err"
    end
  end

  def test_read_stream_returns_empty_string_on_ioerror
    stream = Object.new
    stream.define_singleton_method(:read) { raise IOError }

    assert_equal "", Hive::Tui::Subprocess.send(:read_stream, stream)
  end

  def test_terminate_process_group_ignores_missing_group_for_term_and_kill
    calls = []

    with_replaced_singleton_method(Process, :kill, lambda { |signal, target|
      calls << [ signal, target ]
      raise Errno::ESRCH
    }) do
      with_replaced_singleton_method(Hive::Tui::Subprocess, :sleep, ->(_seconds) { }) do
        assert_nil Hive::Tui::Subprocess.send(:terminate_process_group, 12_345)
      end
    end

    assert_equal [ [ "TERM", -12_345 ], [ "KILL", -12_345 ] ], calls
  end

  def test_safe_thread_value_kills_live_threads_and_rescues_value_errors
    killed = false
    live_thread = Object.new
    live_thread.define_singleton_method(:alive?) { true }
    live_thread.define_singleton_method(:kill) { killed = true }
    live_thread.define_singleton_method(:value) { "done" }

    assert_equal "done", Hive::Tui::Subprocess.send(:safe_thread_value, live_thread)
    assert killed

    broken_thread = Object.new
    broken_thread.define_singleton_method(:alive?) { raise "status unavailable" }

    assert_equal "", Hive::Tui::Subprocess.send(:safe_thread_value, broken_thread)
  end

  def test_translate_status_returns_minus_one_when_status_has_no_exit_or_signal
    status = Object.new
    status.define_singleton_method(:exitstatus) { nil }
    status.define_singleton_method(:signaled?) { false }

    assert_equal(-1, Hive::Tui::Subprocess.send(:translate_status, status))
  end

  def test_parse_argv_from_section_returns_nil_for_unmatched_header
    assert_nil Hive::Tui::Subprocess.send(:parse_argv_from_section, "not a BEGIN line\n")
  end

  def with_log_dir
    old = ENV["HIVE_TUI_LOG_DIR"]
    Dir.mktmpdir do |dir|
      ENV["HIVE_TUI_LOG_DIR"] = dir
      yield dir
    end
  ensure
    old.nil? ? ENV.delete("HIVE_TUI_LOG_DIR") : ENV["HIVE_TUI_LOG_DIR"] = old
  end
end
