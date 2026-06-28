require "test_helper"
require "hive/task"
require "hive/task_action"

class DiagnosticEvidenceTest < Minitest::Test
  def test_prefers_red_status_frontmatter_summary
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      path = File.join(folder, "diagnostics", "red-status.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~MD)
        ---
        summary: Agent found the root cause
        generated_by: codex
        diagnosed_at: 2026-06-28T00:00:00Z
        ---
        Body should not win.
      MD

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "Agent found the root cause", evidence.fetch(:summary)
      assert_equal path, evidence.fetch(:source_path)
      assert_equal :red_status, evidence.fetch(:kind)
    end
  end

  def test_red_status_falls_back_to_first_body_line
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      path = File.join(folder, "diagnostics", "red-status.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~MD)
        ---
        generated_by: codex
        ---

        Body summary wins
      MD

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "Body summary wins", evidence.fetch(:summary)
      assert_equal path, evidence.fetch(:source_path)
    end
  end

  def test_malformed_red_status_frontmatter_falls_back_to_body
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      path = File.join(folder, "diagnostics", "red-status.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~MD)
        ---
        summary: [
        ---
        Body after bad yaml
      MD

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "Body after bad yaml", evidence.fetch(:summary)
      assert_equal path, evidence.fetch(:source_path)
    end
  end

  def test_non_hash_red_status_frontmatter_falls_back_to_body
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      path = File.join(folder, "diagnostics", "red-status.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~MD)
        ---
        - not
        - a
        - hash
        ---
        Body after array yaml
      MD

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "Body after array yaml", evidence.fetch(:summary)
      assert_equal path, evidence.fetch(:source_path)
    end
  end

  def test_empty_red_status_without_lower_tier_evidence_returns_nil
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      path = File.join(folder, "diagnostics", "red-status.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")

      assert_nil Hive::DiagnosticEvidence.summarize(folder: folder)
    end
  end

  def test_uses_newest_log_last_meaningful_line_and_marker_summary
    Dir.mktmpdir("hive-diagnostic-evidence") do |root|
      slug = "stuck-task-260628-abcd"
      folder = File.join(root, ".hive-state", "stages", "4-execute", slug)
      global_logs = File.join(root, ".hive-state", "logs", slug)
      local_logs = File.join(folder, "logs")
      FileUtils.mkdir_p([ folder, global_logs, local_logs ])
      old_log = File.join(local_logs, "old.log")
      new_log = File.join(global_logs, "new.log")
      File.write(old_log, "old line\n")
      File.write(new_log, "first\n\nlatest failure line\n")
      File.utime(Time.now - 60, Time.now - 60, old_log)
      File.utime(Time.now, Time.now, new_log)

      evidence = Hive::DiagnosticEvidence.summarize(
        folder: folder,
        marker_summary: "ERROR reason=boom"
      )

      assert_equal "ERROR reason=boom: latest failure line", evidence.fetch(:summary)
      assert_equal new_log, evidence.fetch(:source_path)
      assert_equal :log, evidence.fetch(:kind)
    end
  end

  def test_skips_empty_newer_log_for_older_meaningful_log
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      older = File.join(logs, "older.log")
      newer = File.join(logs, "newer.log")
      File.write(older, "real failure\n")
      File.write(newer, "\n\n")
      File.utime(Time.now - 60, Time.now - 60, older)
      File.utime(Time.now, Time.now, newer)

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "real failure", evidence.fetch(:summary)
      assert_equal older, evidence.fetch(:source_path)
    end
  end

  def test_uses_marker_only_when_no_log_or_red_status_exists
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- ERROR reason=worktree_git_failed marker_id=hidden -->\n")

      evidence = Hive::DiagnosticEvidence.summarize(
        folder: folder,
        marker_summary: "ERROR reason=worktree_git_failed"
      )

      assert_equal "ERROR reason=worktree_git_failed", evidence.fetch(:summary)
      assert_equal state_file, evidence.fetch(:source_path)
      assert_equal :marker, evidence.fetch(:kind)
    end
  end

  def test_threaded_authoritative_state_file_pins_marker_tier_source
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      # An advanced folder carries a stale marker in an earlier-stage file
      # (task.md) AND the canonical state file (pr.md). Without threading, the
      # resolver globs task.md first and mislabels the marker source.
      File.write(File.join(folder, "task.md"), "<!-- COMPLETE -->\n")
      pr_md = File.join(folder, "pr.md")
      File.write(pr_md, "<!-- REVIEW_STALE pass=2 -->\n")

      evidence = Hive::DiagnosticEvidence.summarize(
        folder: folder,
        marker_summary: "REVIEW_STALE pass=2",
        state_file: pr_md
      )

      assert_equal :marker, evidence.fetch(:kind)
      assert_equal pr_md, evidence.fetch(:source_path),
                   "marker tier must point at the authoritative state file, not the first glob hit"
      assert_equal "REVIEW_STALE pass=2", evidence.fetch(:summary)
    end
  end

  def test_derives_marker_summary_when_not_supplied
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- ERROR -->\n")

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "ERROR", evidence.fetch(:summary)
      assert_equal state_file, evidence.fetch(:source_path)
    end
  end

  def test_finds_marker_in_nonstandard_markdown_file
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      state_file = File.join(folder, "notes.md")
      File.write(state_file, "<!-- REVIEW_STALE pass=2 -->\n")

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "REVIEW_STALE pass=2", evidence.fetch(:summary)
      assert_equal state_file, evidence.fetch(:source_path)
    end
  end

  def test_empty_folder_returns_nil
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      assert_nil Hive::DiagnosticEvidence.summarize(folder: folder)
    end
  end

  def test_missing_or_blank_folder_returns_nil
    assert_nil Hive::DiagnosticEvidence.summarize(folder: "/tmp/missing-hive-diagnostic-evidence")
    assert_nil Hive::DiagnosticEvidence.summarize(folder: " ")
  end

  def test_redacts_secret_looking_log_lines
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      path = File.join(logs, "secret.log")
      File.write(path, "token AKIA1234567890123456 leaked\n")

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_includes evidence.fetch(:summary), "[REDACTED:aws_access_key]"
      refute_includes evidence.fetch(:summary), "AKIA1234567890123456"
    end
  end

  def test_truncates_long_log_summary
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      path = File.join(logs, "long.log")
      File.write(path, "x" * 200)

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal Hive::DiagnosticEvidence::SUMMARY_MAX, evidence.fetch(:summary).length
      assert evidence.fetch(:summary).end_with?("…")
    end
  end

  def test_invalid_utf8_log_tail_does_not_raise
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      path = File.join(logs, "binary.log")
      File.binwrite(path, "before\nbad byte \xFF\n".b)

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal "bad byte ?", evidence.fetch(:summary)
      assert_equal Encoding::UTF_8, evidence.fetch(:summary).encoding
    end
  end

  def test_defensive_helpers_degrade_without_raising
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      FileUtils.mkdir_p(File.join(folder, "task.md"))

      marker = nil
      # task.md is a directory here → EISDIR (a real, non-ENOENT fault) must
      # degrade to nil with a stderr breadcrumb rather than crash.
      _out, err = capture_io do
        marker = Hive::DiagnosticEvidence.send(:current_marker, File.join(folder, "task.md"))
      end
      assert_nil marker
      assert_match(/cannot read marker/, err)

      assert_equal "", Hive::DiagnosticEvidence.send(:safe_read_head, File.join(folder, "missing.md"))
      assert_nil Hive::DiagnosticEvidence.send(:safe_mtime, File.join(folder, "missing.md"))
      assert_nil Hive::DiagnosticEvidence.send(:last_meaningful_line, File.join(folder, "missing.log"))
    end
  end

  def test_log_candidate_glob_failures_degrade_to_empty_with_breadcrumb
    original = Dir.method(:[])
    Dir.define_singleton_method(:[]) do |*_args|
      raise Errno::EIO, "simulated"
    end

    result = nil
    _out, err = capture_io { result = Hive::DiagnosticEvidence.send(:log_candidates, "/tmp/anything") }
    assert_equal [], result
    # A real I/O fault (not ENOENT) must leave a stderr breadcrumb, not vanish.
    assert_match(/log glob failed/, err)
  ensure
    Dir.define_singleton_method(:[], original) if original
  end

  def test_state_file_candidate_glob_failures_degrade_to_empty_with_breadcrumb
    original = Dir.method(:[])
    Dir.define_singleton_method(:[]) do |*_args|
      raise Errno::EIO, "simulated"
    end

    result = nil
    _out, err = capture_io { result = Hive::DiagnosticEvidence.send(:state_file_candidates, "/tmp/anything") }
    assert_equal [], result
    assert_match(/state-file glob failed/, err)
  ensure
    Dir.define_singleton_method(:[], original) if original
  end

  # R4 net, marker-only resolver path. Non-red markers never reach TaskAction's
  # diagnostic (it returns nil), so DiagnosticEvidence is the production net for
  # them. Drive its marker tier for real — NO red-status, NO log planted — so
  # the marker-only branch is actually exercised (the prior version always
  # planted a log, leaving the marker tier untested). Each must resolve to
  # marker-tier evidence whose summary names the marker and whose source is the
  # state file.
  def test_marker_only_resolver_path_has_non_empty_evidence
    markers = [
      "COMPLETE",
      "WAITING",
      "REVIEW_STALE pass=2 reason=max_passes",
      "EXECUTE_STALE findings_count=3"
    ]

    markers.each do |marker_text|
      Dir.mktmpdir("hive-diagnostic-evidence-marker") do |folder|
        state_file = File.join(folder, "task.md")
        File.write(state_file, "<!-- #{marker_text} -->\n")

        evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

        refute_nil evidence, "marker-only task #{marker_text.inspect} must resolve to evidence"
        assert_equal :marker, evidence.fetch(:kind)
        assert_equal state_file, evidence.fetch(:source_path)
        refute_empty evidence.fetch(:summary)
        assert_includes evidence.fetch(:summary), marker_text.split.first
        # NOTE: the "No diagnostic available" R7 guard belongs at the bot/CLI
        # render layer (covered there), not here — the resolver returns a hash
        # and structurally never emits that phrase, so asserting its absence on
        # a string built from that hash would be tautological.
      end
    end
  end

  # R4 net, production-diagnostic path. The red-recovery markers AND the
  # synthetic states (PLAN_MISSING_OUTPUT / FINALIZE_* / stale-agent) yield a
  # non-nil Diagnostic in production, so the resolver is never reached for them.
  # Assert them on the real TaskAction path instead of echoing literal strings
  # the way the prior sweep did.
  def test_red_and_synthetic_states_have_non_empty_production_diagnostics
    cases = [
      # [stage_dir, state_filename, content-or-nil, TaskAction.for kwargs, summary substring]
      [ "4-execute", "task.md", "<!-- ERROR reason=exit_code exit_code=1 -->\n", {}, "ERROR" ],
      [ "6-review", "task.md", "<!-- REVIEW_ERROR phase=fix pass=1 -->\n", {}, "REVIEW_ERROR" ],
      [ "6-review", "task.md", "<!-- REVIEW_STALE pass=1 reason=max_passes -->\n", {}, "REVIEW_STALE" ],
      [ "6-review", "task.md", "<!-- REVIEW_CI_STALE attempts=2 -->\n", {}, "REVIEW_CI_STALE" ],
      [ "4-execute", "task.md", "<!-- EXECUTE_STALE findings_count=3 -->\n", {}, "EXECUTE_STALE" ],
      # PLAN_MISSING_OUTPUT: plan stage, empty plan.md, no marker.
      [ "3-plan", "plan.md", "", {}, "PLAN_MISSING_OUTPUT" ],
      # FINALIZE_MISSING_PR_MD: finalize stage, pr.md absent entirely.
      [ "8-finalize", "pr.md", nil, {}, "FINALIZE_MISSING_PR_MD" ],
      # FINALIZE_MISSING_PR_URL: COMPLETE in pr.md but no pr_url frontmatter.
      [ "8-finalize", "pr.md", "<!-- COMPLETE -->\n", {}, "FINALIZE_MISSING_PR_URL" ],
      # FINALIZE_PR_URL_MISMATCH: frontmatter pr_url disagrees with marker pr_url.
      [ "8-finalize", "pr.md",
        "---\npr_url: https://github.com/x/y/pull/1\n---\n<!-- COMPLETE pr_url=https://github.com/x/y/pull/2 -->\n",
        {}, "FINALIZE_PR_URL_MISMATCH" ],
      # Stale agent (orphaned): AGENT_WORKING placeholder older than the grace.
      [ "4-execute", "task.md", "<!-- AGENT_WORKING -->\n",
        { pid_alive: nil, state_file_mtime: Time.now - 3600, agent_marker_grace_sec: 1 },
        "agent never attached" ],
      # Stale agent (died): AGENT_WORKING with a recorded pid that is not alive
      # (the :agent_died branch the plan's stale-agent requirement also names).
      [ "4-execute", "task.md", "<!-- AGENT_WORKING pid=999999 -->\n",
        { pid_alive: false },
        "agent process not alive" ]
    ]

    cases.each do |stage_dir, state_filename, content, for_kwargs, expected|
      Dir.mktmpdir("hive-task-action-diagnostic") do |project_root|
        slug = "red-task-260628-abcd"
        folder = File.join(project_root, ".hive-state", "stages", stage_dir, slug)
        FileUtils.mkdir_p(folder)
        task = Hive::Task.new(folder)
        assert_equal File.join(folder, state_filename), task.state_file,
                     "fixture state file must match the workflow stage's state file"
        File.write(task.state_file, content) unless content.nil?

        marker = Hive::Markers.current(task.state_file)
        diagnostic = Hive::TaskAction.for(task, marker, **for_kwargs).diagnostic

        assert_kind_of Hash, diagnostic,
                       "#{stage_dir}/#{expected} must produce a non-nil production diagnostic"
        refute_empty diagnostic.fetch("summary")
        assert_includes diagnostic.fetch("summary"), expected
      end
    end
  end

  # The >8KB tail seek path: a log larger than TAIL_BYTES forces
  # seek(-TAIL_BYTES, SEEK_END) to succeed (rather than EINVAL→rewind), and the
  # partial first line of the window is dropped. The final meaningful line must
  # still be picked, and content before the window must not appear.
  def test_large_log_tail_uses_seek_path_and_drops_partial_first_line
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      big = File.join(logs, "big.log")
      File.write(big, "EARLY_BEFORE_WINDOW\n#{'x' * 9000}\nFINAL_TAIL_LINE\n")

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_includes evidence.fetch(:summary), "FINAL_TAIL_LINE"
      refute_includes evidence.fetch(:summary), "EARLY_BEFORE_WINDOW"
      assert_equal big, evidence.fetch(:source_path)
      assert_equal :log, evidence.fetch(:kind)
    end
  end

  # Tail-boundary redaction bypass: a secret on a single line longer than
  # TAIL_BYTES that is also the file's last line begins before the seek window,
  # so its `sk-` prefix is chopped and prefix-anchored redaction can't match.
  # Dropping the partial first line suppresses the leak; evidence falls back to
  # the marker tier.
  def test_secret_split_across_tail_boundary_does_not_leak
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- ERROR reason=boom -->\n")
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "huge.log"), "sk-#{'A' * 9000}\n")

      evidence = Hive::DiagnosticEvidence.summarize(
        folder: folder,
        marker_summary: "ERROR reason=boom"
      )

      refute_match(/A{30,}/, evidence.fetch(:summary), "boundary-split secret must not leak")
      refute_includes evidence.fetch(:summary), "sk-"
      assert_equal "ERROR reason=boom", evidence.fetch(:summary)
      assert_equal state_file, evidence.fetch(:source_path)
      assert_equal :marker, evidence.fetch(:kind)
    end
  end

  # Symlinked evidence escaping the task/log roots must be refused, not read —
  # otherwise a `*.log` symlink under logs/ leaks an arbitrary host file.
  def test_symlinked_log_outside_roots_is_not_followed
    Dir.mktmpdir("hive-diagnostic-evidence-secret") do |outside|
      secret = File.join(outside, "secret.txt")
      File.write(secret, "TOP_SECRET_HOST_FILE\n")

      Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
        state_file = File.join(folder, "task.md")
        File.write(state_file, "<!-- ERROR reason=boom -->\n")
        logs = File.join(folder, "logs")
        FileUtils.mkdir_p(logs)
        File.symlink(secret, File.join(logs, "evil.log"))

        evidence = Hive::DiagnosticEvidence.summarize(
          folder: folder,
          marker_summary: "ERROR reason=boom"
        )

        refute_includes evidence.fetch(:summary), "TOP_SECRET_HOST_FILE"
        # Falls back to the marker tier (the only contained evidence).
        assert_equal :marker, evidence.fetch(:kind)
        assert_equal state_file, evidence.fetch(:source_path)
      end
    end
  end

  # A dangling `*.log` symlink can't be realpath'd (ENOENT) — it is skipped
  # silently (a vanished file is benign), and evidence falls back to the marker.
  def test_dangling_symlink_log_is_skipped_silently
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- ERROR reason=boom -->\n")
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      File.symlink("missing-target", File.join(logs, "dangling.log"))

      evidence = nil
      _out, err = capture_io do
        evidence = Hive::DiagnosticEvidence.summarize(folder: folder, marker_summary: "ERROR reason=boom")
      end

      refute_match(/cannot realpath/, err)
      assert_equal :marker, evidence.fetch(:kind)
      assert_equal state_file, evidence.fetch(:source_path)
    end
  end

  # A self-referential `*.log` symlink raises ELOOP on realpath — a non-ENOENT
  # fault that must leave a breadcrumb before the candidate is skipped.
  def test_symlink_loop_log_is_skipped_with_breadcrumb
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- ERROR reason=boom -->\n")
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      File.symlink("loop.log", File.join(logs, "loop.log"))

      evidence = nil
      _out, err = capture_io do
        evidence = Hive::DiagnosticEvidence.summarize(folder: folder, marker_summary: "ERROR reason=boom")
      end

      assert_match(/cannot realpath/, err)
      assert_equal :marker, evidence.fetch(:kind)
      assert_equal state_file, evidence.fetch(:source_path)
    end
  end

  # A non-ENOENT read fault (here ENAMETOOLONG) must degrade each read helper to
  # its benign default WITH a stderr breadcrumb, not silently.
  def test_read_helpers_warn_on_non_enoent_faults
    longpath = "a" * 5000
    head = line = mtime = :unset
    _out, err = capture_io do
      head = Hive::DiagnosticEvidence.send(:safe_read_head, longpath)
      line = Hive::DiagnosticEvidence.send(:last_meaningful_line, longpath)
      mtime = Hive::DiagnosticEvidence.send(:safe_mtime, longpath)
    end

    assert_equal "", head
    assert_nil line
    assert_nil mtime
    assert_match(/cannot read head/, err)
    assert_match(/cannot read log tail/, err)
    assert_match(/cannot stat/, err)
  end

  # Invalid UTF-8 in a state file makes Markers.current's scan raise
  # ArgumentError; current_marker treats it as "no marker", not a crash — and
  # leaves a breadcrumb (matching the SystemCallError branch) so a corrupt
  # state file doesn't vanish from the evidence with zero signal.
  def test_current_marker_invalid_utf8_degrades_to_nil_with_breadcrumb
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      path = File.join(folder, "task.md")
      File.binwrite(path, "<!-- ERROR \xFF reason=boom -->\n".b)

      marker = :unset
      _out, err = capture_io do
        marker = Hive::DiagnosticEvidence.send(:current_marker, path)
      end
      assert_nil marker
      assert_match(/cannot parse marker/, err)
    end
  end

  # summarize must never raise: an unexpected error from any tier helper degrades
  # to nil with a breadcrumb so the CLI doesn't exit 70 and the bot reap loop
  # keeps replying to other children.
  def test_summarize_outer_rescue_degrades_to_nil_with_breadcrumb
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      original = Hive::DiagnosticEvidence.method(:red_status_summary)
      Hive::DiagnosticEvidence.define_singleton_method(:red_status_summary) do |*|
        raise "boom from red_status_summary"
      end

      result = :unset
      _out, err = capture_io do
        result = Hive::DiagnosticEvidence.summarize(folder: folder)
      end

      assert_nil result
      assert_match(/summarize degraded/, err)
    ensure
      Hive::DiagnosticEvidence.define_singleton_method(:red_status_summary, original) if original
    end
  end

  # An oversized state file (> MARKER_READ_MAX) is junk for a marker scan and
  # must be skipped rather than slurped whole — otherwise the bot reaper thread
  # could OOM (NoMemoryError) straight through the never-raise rescue.
  def test_oversized_state_file_marker_read_is_skipped_with_breadcrumb
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      path = File.join(folder, "task.md")
      File.write(path, "#{'x' * (Hive::DiagnosticEvidence::MARKER_READ_MAX + 10)}\n<!-- ERROR reason=boom -->\n")

      marker = :unset
      _out, err = capture_io do
        marker = Hive::DiagnosticEvidence.send(:current_marker, path)
      end
      assert_nil marker, "an oversized state file must be skipped, not slurped"
      assert_match(/skipping marker read/, err)
    end
  end

  # The marker size probe must not become a second silent failure point: a stat
  # fault (here ENAMETOOLONG) degrades to "not oversized" and lets the read
  # attempt and its own rescue handle the fault.
  def test_marker_size_probe_degrades_when_stat_faults
    assert_nil Hive::DiagnosticEvidence.send(:current_marker, "b" * 5000)
  end

  # The lazy `require "hive/task"` raises LoadError (a ScriptError, not a
  # StandardError) if hive/task can't load; that must degrade the inferred-log
  # tier to nil with a breadcrumb, not escape summarize's StandardError rescue.
  def test_inferred_task_log_dir_load_error_degrades_with_breadcrumb
    folder = File.join("/tmp", ".hive-state", "stages", "4-execute", "slug-260628-abcd")
    Hive::DiagnosticEvidence.define_singleton_method(:require) { |*| raise LoadError, "simulated" }

    result = :unset
    _out, err = capture_io do
      result = Hive::DiagnosticEvidence.send(:inferred_task_log_dir, folder)
    end
    assert_nil result
    assert_match(%r{cannot load hive/task}, err)
  ensure
    Hive::DiagnosticEvidence.singleton_class.send(:remove_method, :require)
  end

  # A FIFO named like evidence must be rejected by the regular-file guard so no
  # later tier ever attempts a blocking open(2) on it (which would wedge the
  # bot reaper thread permanently). realpath + File.file? are both non-blocking,
  # so asserting the guard directly can't itself hang on a regression.
  def test_fifo_named_log_is_rejected_by_regular_file_guard
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      fifo = File.join(logs, "newest.log")
      File.mkfifo(fifo)

      refute Hive::DiagnosticEvidence.send(:contained?, fifo, folder),
             "a FIFO named like evidence must be rejected before any open"
    end
  end

  # No-trailing-newline sibling of the boundary-secret test: a single log line
  # longer than TAIL_BYTES with NO internal newline exercises drop_first_line's
  # `: ""` arm (the whole partial fragment is dropped). A regression that
  # returned the partial buffer would leak the prefix-anchored secret's tail.
  def test_secret_single_line_longer_than_tail_no_newline_does_not_leak
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      state_file = File.join(folder, "task.md")
      File.write(state_file, "<!-- ERROR reason=boom -->\n")
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      File.write(File.join(logs, "huge.log"), "sk-#{'A' * 9000}")

      evidence = Hive::DiagnosticEvidence.summarize(
        folder: folder,
        marker_summary: "ERROR reason=boom"
      )

      refute_match(/A{30,}/, evidence.fetch(:summary), "boundary-split secret must not leak")
      refute_includes evidence.fetch(:summary), "sk-"
      assert_equal "ERROR reason=boom", evidence.fetch(:summary)
      assert_equal :marker, evidence.fetch(:kind)
      assert_equal state_file, evidence.fetch(:source_path)
    end
  end

  # The actually-exploitable High #2 case: a symlinked logs/ *directory* (not a
  # file) pointing outside the task roots must NOT be resolved into a trusted
  # root, otherwise every *.log under the target leaks. Falls back to the
  # contained marker tier.
  def test_symlinked_log_directory_outside_roots_is_not_followed
    Dir.mktmpdir("hive-diagnostic-evidence-outside") do |outside|
      File.write(File.join(outside, "leak.log"), "TOP_SECRET_HOST_FILE\n")

      Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
        state_file = File.join(folder, "task.md")
        File.write(state_file, "<!-- ERROR reason=boom -->\n")
        # logs/ is itself a directory symlink to the outside dir.
        File.symlink(outside, File.join(folder, "logs"))

        evidence = Hive::DiagnosticEvidence.summarize(
          folder: folder,
          marker_summary: "ERROR reason=boom"
        )

        refute_includes evidence.fetch(:summary), "TOP_SECRET_HOST_FILE"
        assert_equal :marker, evidence.fetch(:kind)
        assert_equal state_file, evidence.fetch(:source_path)
      end
    end
  end

  # The red-status tier's contained? refusal: a diagnostics/red-status.md that
  # is a symlink to an outside file must not surface the host content; evidence
  # falls back to the marker tier.
  def test_symlinked_red_status_outside_roots_is_refused
    Dir.mktmpdir("hive-diagnostic-evidence-outside") do |outside|
      secret = File.join(outside, "secret.md")
      File.write(secret, <<~MD)
        ---
        summary: HOST_RED_STATUS_LEAK
        ---
        body
      MD

      Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
        state_file = File.join(folder, "task.md")
        File.write(state_file, "<!-- ERROR reason=boom -->\n")
        diagnostics = File.join(folder, "diagnostics")
        FileUtils.mkdir_p(diagnostics)
        File.symlink(secret, File.join(diagnostics, "red-status.md"))

        evidence = Hive::DiagnosticEvidence.summarize(
          folder: folder,
          marker_summary: "ERROR reason=boom"
        )

        refute_includes evidence.fetch(:summary), "HOST_RED_STATUS_LEAK"
        assert_equal :marker, evidence.fetch(:kind)
        assert_equal state_file, evidence.fetch(:source_path)
      end
    end
  end

  # The marker tier's contained? refusal: a *.md state-file candidate that is a
  # symlink to an outside file carrying a marker must not surface; the resolver
  # uses the contained sibling instead and the host marker never appears.
  def test_symlinked_marker_state_file_outside_roots_is_refused
    Dir.mktmpdir("hive-diagnostic-evidence-outside") do |outside|
      secret = File.join(outside, "secret.md")
      File.write(secret, "<!-- REVIEW_STALE pass=99 leak=HOST_MARKER_LEAK -->\n")

      Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
        File.symlink(secret, File.join(folder, "task.md"))
        File.write(File.join(folder, "notes.md"), "<!-- ERROR reason=contained -->\n")

        evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

        refute_includes evidence.fetch(:summary), "HOST_MARKER_LEAK"
        assert_equal :marker, evidence.fetch(:kind)
        assert_equal File.join(folder, "notes.md"), evidence.fetch(:source_path)
        assert_equal "ERROR reason=contained", evidence.fetch(:summary)
      end
    end
  end

  # plan R2: the newest log by MTIME must be picked even when its filename sorts
  # earlier than older logs and the candidate set exceeds LOG_GLOB_CAP. The old
  # cap-by-filename-then-mtime ordering dropped a newest-but-early-named log
  # before the mtime sort ever saw it.
  def test_newest_log_by_mtime_wins_even_with_early_filename
    Dir.mktmpdir("hive-diagnostic-evidence") do |folder|
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      cap = Hive::DiagnosticEvidence::LOG_GLOB_CAP
      newest = File.join(logs, "log_00.log") # sorts FIRST lexically
      File.write(newest, "NEWEST_BY_MTIME\n")
      File.utime(Time.now, Time.now, newest)
      # cap older logs whose filenames all sort AFTER log_00 → the filename cap
      # would have dropped log_00 (the freshest) before any stat.
      (1..cap).each do |i|
        older = File.join(logs, format("log_%02d.log", i))
        File.write(older, "older line #{i}\n")
        File.utime(Time.now - 3600, Time.now - 3600, older)
      end

      evidence = Hive::DiagnosticEvidence.summarize(folder: folder)

      assert_equal :log, evidence.fetch(:kind)
      assert_equal newest, evidence.fetch(:source_path)
      assert_includes evidence.fetch(:summary), "NEWEST_BY_MTIME"
    end
  end
end
