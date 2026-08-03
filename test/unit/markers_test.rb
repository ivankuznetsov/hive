require "test_helper"
require "hive/markers"
require "timeout"

class MarkersTest < Minitest::Test
  include HiveTestHelper

  def test_returns_none_for_missing_file
    with_tmp_dir do |dir|
      state = Hive::Markers.current(File.join(dir, "nope.md"))
      assert state.none?, "missing file should report :none"
    end
  end

  def test_current_rejects_symlinks_and_fifos_without_blocking
    skip "File::NONBLOCK is unavailable" unless File.const_defined?(:NONBLOCK)

    with_tmp_dir do |dir|
      target = File.join(dir, "target.md")
      link = File.join(dir, "link.md")
      fifo = File.join(dir, "fifo.md")
      File.write(target, "<!-- COMPLETE -->\n")
      File.symlink(target, link)
      File.mkfifo(fifo, 0o600)

      states = Timeout.timeout(1) do
        [ Hive::Markers.current(link), Hive::Markers.current(fifo) ]
      end

      assert states.all?(&:none?)
      assert_equal "<!-- COMPLETE -->\n", File.read(target)
    end
  end

  def test_current_reads_only_a_bounded_tail_of_a_large_sparse_artifact
    with_tmp_dir do |dir|
      file = File.join(dir, "large.md")
      File.open(file, "wb") do |io|
        io.write("Outcome: verified\n")
        io.seek(32 * 1024 * 1024, IO::SEEK_SET)
        io.write("<!-- COMPLETE -->\n")
      end

      state = Timeout.timeout(1) { Hive::Markers.current(file) }

      assert_equal :complete, state.name
      assert_operator File.size(file), :>, Hive::Markers::MAX_MARKER_SCAN_BYTES
    end
  end

  # `summary` returns null (not the string "NONE") for the :none marker and a
  # nil marker, so a markerless task's diagnose envelope reads marker_summary:
  # null and the evidence resolver omits the prefix. Produce it end-to-end from
  # a real markerless state file rather than asserting a hand-built literal — a
  # regression rendering "NONE" would otherwise pass on hard-coded fixtures.
  def test_summary_is_null_for_none_and_nil_marker
    assert_nil Hive::Markers.summary(nil)
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      File.write(file, "no marker here, just prose\n")
      none = Hive::Markers.current(file)
      assert none.none?, "a markerless file must classify as :none"
      assert_nil Hive::Markers.summary(none),
                 "Markers.summary(:none) must be null, not \"NONE\""
    end
  end

  def test_reads_simple_waiting_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "body\n<!-- WAITING -->\n")
      state = Hive::Markers.current(file)
      assert_equal :waiting, state.name
      assert_empty state.attrs
    end
  end

  def test_takes_last_marker_when_multiple_present
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "<!-- WAITING -->\n## Round 1\n<!-- COMPLETE -->\n")
      state = Hive::Markers.current(file)
      assert_equal :complete, state.name
    end
  end

  def test_parses_attrs
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, %(<!-- AGENT_WORKING pid=12345 started=2026-04-24T10:00:00Z -->\n))
      state = Hive::Markers.current(file)
      assert_equal :agent_working, state.name
      assert_equal "12345", state.attrs["pid"]
      assert_equal "2026-04-24T10:00:00Z", state.attrs["started"]
    end
  end

  def test_marker_projects_attempt_identity_but_hides_it_from_display_attrs
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      with_attempt_context(
        attempt_id: "attempt-1", task_generation: 1, ownership_generation: "generation-1"
      ) do
        Hive::Markers.set(
          file, :waiting,
          attempt_id: "caller-cannot-override",
          task_generation: "caller-cannot-override",
          reason: "question"
        )
      end

      attrs = Hive::Markers.current(file).attrs
      assert_equal "attempt-1", attrs["attempt_id"]
      assert_equal "generation-1", attrs["task_generation"]
      assert_equal "generation-1", attrs["ownership_generation"]
      assert_equal "1", attrs["task_input_epoch"]
      assert_equal({ "reason" => "question" }, Hive::Markers.display_attrs(attrs))
    end
  end

  def test_rejects_marker_names_that_only_prefix_known_names
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "<!-- COMPLETED -->\n<!-- ERROR_DETAIL reason=boom -->\n<!-- REVIEW_COMPLETE_SUFFIX -->\n")

      state = Hive::Markers.current(file)

      assert_equal :none, state.name
      assert_empty state.attrs
    end
  end

  def test_ignores_unterminated_marker_before_later_valid_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, <<~MD)
        <!-- ERROR reason="unterminated
        <!-- COMPLETE -->
      MD

      state = Hive::Markers.current(file)

      assert_equal :complete, state.name
      assert_empty state.attrs
    end
  end

  def test_parses_git_error_detail_with_branch_arrow
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, <<~MD)
        <!-- ERROR reason=unpushed_commits detail="To https://github.com/example/repo.git
         ! [rejected]          branch-a -> branch-a (non-fast-forward)
        error: failed to push some refs to 'origin'" -->
      MD

      state = Hive::Markers.current(file)

      assert_equal :error, state.name
      assert_equal "unpushed_commits", state.attrs["reason"]
      assert_includes state.attrs.fetch("detail"), "branch-a -> branch-a"
    end
  end

  def test_set_sanitizes_quotes_and_comment_delimiters_in_attr_values
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      Hive::Markers.set(file, :error, reason: "boom", detail: 'bad "quoted" <!-- marker --> payload')

      state = Hive::Markers.current(file)

      assert_equal :error, state.name
      assert_equal "boom", state.attrs["reason"]
      assert_equal "bad 'quoted' < !-- marker -- > payload", state.attrs["detail"]
    end
  end


  def test_error_markers_get_unique_marker_id
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")

      Hive::Markers.set(file, :error, reason: "exit_code", exit_code: 1)
      first_id = Hive::Markers.current(file).attrs["marker_id"]

      Hive::Markers.set(file, :error, reason: "exit_code", exit_code: 1)
      second_id = Hive::Markers.current(file).attrs["marker_id"]

      assert_match(/\A[0-9a-f]{16}\z/, first_id)
      assert_match(/\A[0-9a-f]{16}\z/, second_id)
      refute_equal first_id, second_id,
                   "same-shaped ERROR marker rotations need distinct recovery ids"
    end
  end

  def test_error_markers_preserve_explicit_marker_id
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")

      Hive::Markers.set(file, :error, reason: "boom", marker_id: "stable-id")

      assert_equal "stable-id", Hive::Markers.current(file).attrs["marker_id"]
    end
  end

  def test_recovery_marker_id_upgrade_is_compare_and_swap
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "# Task\n<!-- ERROR reason=timeout -->\n")
      observed = Hive::Markers.current(file)

      assert Hive::Markers.upgrade_recovery_marker_id(file, observed: observed)
      upgraded = Hive::Markers.current(file)
      assert_equal "timeout", upgraded.attrs.fetch("reason")
      assert_match(/\A[0-9a-f]{16}\z/, upgraded.attrs.fetch("marker_id"))

      File.write(file, "# Task\n<!-- ERROR reason=newer marker_id=newer-id -->\n")
      refute Hive::Markers.upgrade_recovery_marker_id(file, observed: observed)
      assert_equal "newer-id", Hive::Markers.current(file).attrs.fetch("marker_id"),
                   "a migration read must never overwrite a newer marker generation"
    end
  end

  def test_review_recovery_markers_get_unique_marker_ids
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")

      %i[review_error review_working].each do |name|
        Hive::Markers.set(file, name, phase: "reviewers", pass: 1)
        first_id = Hive::Markers.current(file).attrs.fetch("marker_id")
        Hive::Markers.set(file, name, phase: "reviewers", pass: 1)
        second_id = Hive::Markers.current(file).attrs.fetch("marker_id")

        assert_match(/\A[0-9a-f]{16}\z/, first_id)
        assert_match(/\A[0-9a-f]{16}\z/, second_id)
        refute_equal first_id, second_id,
                     "same-shaped #{name} rotations need distinct recovery ids"
      end
    end
  end

  def test_recovery_match_attr_prefers_marker_id_alone_when_no_reason
    attrs = { "exit_code" => "70", "marker_id" => "err-70" }

    assert_equal "marker_id=err-70", Hive::Markers.recovery_match_attr(attrs)
  end

  # `marker_id` keeps its primary "race-safe clear guard" role, but the
  # bot's inline-button callback path needs `reason` reconstructable
  # from the callback_data so `manual_only?` can route
  # `ensure_clean_on_exit_failed` / `dirty_worktree` into operator-only
  # reply. Encode both as comma-separated pairs; `marker_id` stays the
  # leading token so AlertStore.parse_match_attr's first-token guard
  # still operates on it.
  def test_recovery_match_attr_encodes_marker_id_and_reason_when_both_present
    attrs = { "reason" => "ensure_clean_on_exit_failed", "marker_id" => "err-70" }

    assert_equal "marker_id=err-70,reason=ensure_clean_on_exit_failed",
                 Hive::Markers.recovery_match_attr(attrs)
  end

  def test_recovery_match_attr_rejects_idless_legacy_marker
    attrs = { "reason" => "agent_failed", "exit_code" => "70" }

    assert_nil Hive::Markers.recovery_match_attr(attrs)
  end

  def test_display_attrs_hides_internal_marker_id
    attrs = { "reason" => "exit_code", "marker_id" => "err-70" }

    assert_equal({ "reason" => "exit_code" }, Hive::Markers.display_attrs(attrs))
  end

  def test_set_appends_marker_to_empty_file
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      Hive::Markers.set(file, :waiting)
      assert_includes File.read(file), "<!-- WAITING -->"
    end
  end

  def test_set_replaces_last_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, "## Round 1\n<!-- WAITING -->\n")
      Hive::Markers.set(file, :complete)
      content = File.read(file)
      assert_includes content, "<!-- COMPLETE -->"
      refute_includes content, "<!-- WAITING -->"
      assert_includes content, "## Round 1", "body content must be preserved"
    end
  end

  def test_set_writes_attrs
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      Hive::Markers.set(file, :agent_working, pid: 12_345, started: "2026-04-24T10:00:00Z")
      content = File.read(file)
      assert_match(/<!-- AGENT_WORKING pid=12345 started=2026-04-24T10:00:00Z -->/, content)
    end
  end

  def test_set_tolerates_fsync_failure
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      original_create = Tempfile.method(:create)
      Tempfile.define_singleton_method(:create) do |*args, **kwargs|
        handle = original_create.call(*args, **kwargs)
        handle.define_singleton_method(:fsync) { raise IOError, "fsync unavailable" }
        handle
      end

      Hive::Markers.set(file, :waiting)

      assert_equal :waiting, Hive::Markers.current(file).name
    ensure
      Tempfile.define_singleton_method(:create, original_create)
    end
  end

  def test_set_ignores_preplanted_predictable_temp_symlink
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      outside = File.join(dir, "outside.md")
      predictable = File.join(dir, ".x.md.tmp.#{Process.pid}")
      File.write(outside, "outside stays intact\n")
      File.symlink(outside, predictable)

      Hive::Markers.set(file, :error, reason: "terminal_outcome_blocked")

      assert_equal "outside stays intact\n", File.read(outside)
      assert File.symlink?(predictable)
      assert_equal :error, Hive::Markers.current(file).name
    end
  end

  def test_set_rejects_temporary_file_identity_substitution_before_rename
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      original = File.method(:lstat)
      fake = Struct.new(:file?, :symlink?, :dev, :ino).new(true, false, -1, -1)
      replacement = lambda do |path|
        File.basename(path).start_with?(".x.md.tmp.") ? fake : original.call(path)
      end

      error = with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(IOError) { Hive::Markers.set(file, :waiting) }
      end

      assert_includes error.message, "temporary file identity changed"
      refute File.exist?(file)
    end
  end

  def test_set_rejects_installed_file_identity_substitution_after_rename
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      original = File.method(:lstat)
      fake = Struct.new(:file?, :symlink?, :dev, :ino).new(true, false, -1, -1)
      replacement = ->(path) { path == file ? fake : original.call(path) }

      error = with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(IOError) { Hive::Markers.set(file, :waiting) }
      end

      assert_includes error.message, "identity changed during atomic rename"
      assert File.file?(file)
    end
  end

  def test_unknown_marker_raises
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      assert_raises(ArgumentError) { Hive::Markers.set(file, :unknown) }
    end
  end

  def test_manual_steering_round_trip
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, "MANUAL_STEERING", agent: "claude", started_at: "2026-05-15T12:00:00Z")

      state = Hive::Markers.current(file)
      assert_equal :manual_steering, state.name
      assert_equal "claude", state.attrs["agent"]
      assert_equal "2026-05-15T12:00:00Z", state.attrs["started_at"]
    end
  end

  def test_unknown_manual_steering_typo_raises
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      err = assert_raises(ArgumentError) { Hive::Markers.set(file, "MANUAL_STEERINGS") }
      assert_equal "unknown marker MANUAL_STEERINGS", err.message
    end
  end

  # Regression from smoke: when an agent uses an in-place Edit tool (rather
  # than a full-file Write), the AGENT_WORKING marker hive set before spawn
  # remains at the top of the file, with the agent's terminal marker (e.g.,
  # WAITING) appended at the bottom. Markers.current must return the *last*
  # marker so state stays correct even though the file is noisy.
  def test_agent_working_left_in_file_does_not_override_terminal_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "x.md")
      File.write(file, <<~MD)
        <!-- AGENT_WORKING pid=1234 started=2026-04-25T10:00Z -->

        ## Round 1
        ### Q1.
        ### A1.

        <!-- WAITING -->
      MD
      state = Hive::Markers.current(file)
      assert_equal :waiting, state.name, "terminal marker must win even with stale AGENT_WORKING above"
    end
  end

  # --- REVIEW_* markers (U3) ---------------------------------------------

  # The 6-review stage's state machine carries six new markers. Each must
  # round-trip through set/current with attributes intact. KNOWN_NAMES and
  # MARKER_RE are two sources of truth — these tests exercise both at once
  # by writing via set (validates KNOWN_NAMES) and reading via current
  # (validates MARKER_RE).

  def test_review_working_round_trip
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_working, phase: :ci, pass: 1)
      state = Hive::Markers.current(file)
      assert_equal :review_working, state.name
      assert_equal "ci", state.attrs["phase"]
      assert_equal "1", state.attrs["pass"]
    end
  end

  def test_review_waiting_round_trip
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_waiting, escalations: 3, pass: 2)
      state = Hive::Markers.current(file)
      assert_equal :review_waiting, state.name
      assert_equal "3", state.attrs["escalations"]
      assert_equal "2", state.attrs["pass"]
    end
  end

  def test_review_ci_stale_round_trip
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_ci_stale, attempts: 3)
      state = Hive::Markers.current(file)
      assert_equal :review_ci_stale, state.name
      assert_equal "3", state.attrs["attempts"]
      assert_match(/\A[0-9a-f]{16}\z/, state.attrs.fetch("marker_id"))
    end
  end

  def test_review_stale_round_trip
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_stale, pass: 4)
      state = Hive::Markers.current(file)
      assert_equal :review_stale, state.name
      assert_equal "4", state.attrs["pass"]
      assert_match(/\A[0-9a-f]{16}\z/, state.attrs.fetch("marker_id"))
    end
  end

  def test_review_complete_round_trip
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_complete, pass: 3, browser: :passed)
      state = Hive::Markers.current(file)
      assert_equal :review_complete, state.name
      assert_equal "3", state.attrs["pass"]
      assert_equal "passed", state.attrs["browser"]
    end
  end

  def test_review_error_round_trip
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_error, phase: :reviewers, reason: "all_failed")
      state = Hive::Markers.current(file)
      assert_equal :review_error, state.name
      assert_equal "reviewers", state.attrs["phase"]
      assert_equal "all_failed", state.attrs["reason"]
    end
  end

  # ADR-005 last-marker-wins rule: writing REVIEW_WORKING phase=triage over
  # an existing REVIEW_WORKING phase=reviewers leaves only the new one as
  # the active marker. set replaces the LAST marker in the file (per
  # replace_last_marker), so a transient phase update doesn't accumulate.
  def test_review_working_phase_update_overwrites_previous
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_working, phase: :reviewers, pass: 1)
      Hive::Markers.set(file, :review_working, phase: :triage, pass: 1)
      content = File.read(file)
      assert_includes content, "<!-- REVIEW_WORKING phase=triage pass=1 marker_id="
      refute_includes content, "<!-- REVIEW_WORKING phase=reviewers pass=1",
                      "previous transient marker must be replaced, not accumulated"
      state = Hive::Markers.current(file)
      assert_equal :review_working, state.name
      assert_equal "triage", state.attrs["phase"]
    end
  end

  def test_guarded_clear_can_purge_shadowed_marker_history_for_daemon_retry
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      File.write(file, <<~MD)
        # status history

        <!-- AGENT_WORKING pid=100 -->
        first attempt
        <!-- ERROR reason=limits_reached marker_id=old -->
        <!-- AGENT_WORKING pid=200 -->
        second attempt
        <!-- ERROR reason=limits_reached marker_id=current -->
      MD

      cleared = Hive::Markers.clear_current(
        file,
        expected_name: :error,
        match_attrs: { marker_id: "current" },
        purge_history: true
      )

      assert cleared
      assert Hive::Markers.current(file).none?
      assert_includes File.read(file), "# status history"
      assert_includes File.read(file), "second attempt"
      refute_match Hive::Markers::MARKER_RE, File.read(file)
    end
  end

  def test_guarded_clear_without_purge_removes_only_the_current_marker
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      File.write(file, <<~MD)
        # status history

        <!-- ERROR reason=first marker_id=old -->
        second attempt
        <!-- ERROR reason=second marker_id=current -->
      MD

      cleared = Hive::Markers.clear_current(
        file,
        expected_name: :error,
        match_attrs: { marker_id: "current" }
      )

      assert cleared
      assert_equal "old", Hive::Markers.current(file).attrs.fetch("marker_id")
      assert_includes File.read(file), "second attempt"
      refute_includes File.read(file), "marker_id=current"
    end
  end

  # The orchestrator-owns-terminal-marker rule (ADR-005) means a transient
  # REVIEW_WORKING is replaced by the terminal marker when the phase
  # finalizes. Verify the transition from REVIEW_WORKING phase=fix to
  # REVIEW_WAITING (a typical "found escalations" outcome).
  def test_review_working_to_review_waiting_transition
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      Hive::Markers.set(file, :review_working, phase: :fix, pass: 2)
      Hive::Markers.set(file, :review_waiting, escalations: 1, pass: 2)
      state = Hive::Markers.current(file)
      assert_equal :review_waiting, state.name
      assert_equal "1", state.attrs["escalations"]
    end
  end

  # The current Markers.set replaces the LAST marker in the file. A noisy
  # task.md (e.g., a stale AGENT_WORKING from the spawn followed by a
  # REVIEW_WORKING the runner set) means set replaces the REVIEW_WORKING,
  # not the AGENT_WORKING. Verify Markers.current still returns the last.
  def test_review_complete_after_noisy_history
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      File.write(file, <<~MD)
        <!-- AGENT_WORKING pid=999 started=2026-04-25T20:00Z -->

        ## Implementation

        <!-- REVIEW_WORKING phase=browser pass=2 -->
      MD
      Hive::Markers.set(file, :review_complete, pass: 2, browser: :passed)
      state = Hive::Markers.current(file)
      assert_equal :review_complete, state.name
      assert_equal "2", state.attrs["pass"]
      content = File.read(file)
      assert_includes content, "<!-- AGENT_WORKING pid=999",
                      "stale AGENT_WORKING must remain (set replaces only the last marker)"
    end
  end

  def test_unknown_review_marker_name_raises
    with_tmp_dir do |dir|
      file = File.join(dir, "task.md")
      assert_raises(ArgumentError) { Hive::Markers.set(file, :review_typo) }
    end
  end
end
