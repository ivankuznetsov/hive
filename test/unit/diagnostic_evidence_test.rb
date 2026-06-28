require "test_helper"

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

      assert_nil Hive::DiagnosticEvidence.current_marker(File.join(folder, "task.md"))
      assert_equal "", Hive::DiagnosticEvidence.safe_read_head(File.join(folder, "missing.md"))
      assert_nil Hive::DiagnosticEvidence.safe_mtime(File.join(folder, "missing.md"))
      assert_nil Hive::DiagnosticEvidence.last_meaningful_line(File.join(folder, "missing.log"))
    end
  end

  def test_log_candidate_glob_failures_degrade_to_empty
    original = Dir.method(:[])
    Dir.define_singleton_method(:[]) do |*_args|
      raise Errno::EIO, "simulated"
    end

    assert_equal [], Hive::DiagnosticEvidence.log_candidates("/tmp/anything")
  ensure
    Dir.define_singleton_method(:[], original) if original
  end

  def test_state_file_candidate_glob_failures_degrade_to_empty
    original = Dir.method(:[])
    Dir.define_singleton_method(:[]) do |*_args|
      raise Errno::EIO, "simulated"
    end

    assert_equal [], Hive::DiagnosticEvidence.state_file_candidates("/tmp/anything")
  ensure
    Dir.define_singleton_method(:[], original) if original
  end
end
