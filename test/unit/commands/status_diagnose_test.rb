require "test_helper"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require "hive/commands/status"
require "hive/diagnosis_agent"

class StatusDiagnoseTest < Minitest::Test
  def with_review_task
    Dir.mktmpdir("hive-status-diagnose") do |project_root|
      slug = "red-task-260516-aaaa"
      folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      File.write(File.join(folder, "task.md"), "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
      File.write(File.join(folder, "reviews", "errors-01.md"), "fix failed\n")
      yield folder, slug
    end
  end

  def test_diagnose_json_emits_local_diagnostic
    with_review_task do |folder, slug|
      out, = capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder).call
      end

      payload = JSON.parse(out)
      assert_equal "hive-status-diagnose", payload["schema"]
      assert_equal slug, payload["slug"]
      assert_equal "local", payload.dig("diagnostic", "generated_by")
      assert_includes payload.dig("diagnostic", "detail"), "fix failed"
    end
  end

  def test_diagnose_write_uses_agent_artifact_when_fresh
    with_review_task do |folder, _slug|
      sentinel = Hive::DiagnosisAgent.method(:run!)
      seen_local_diagnostic = nil
      Hive::DiagnosisAgent.define_singleton_method(:run!) do |task:, local_diagnostic:|
        seen_local_diagnostic = local_diagnostic
        marker_signature = Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix")
        diagnostics = File.join(task.folder, "diagnostics")
        FileUtils.mkdir_p(diagnostics)
        path = File.join(diagnostics, "red-status.md")
        File.write(path, <<~MD)
          ---
          generated_by: codex
          marker_signature: #{marker_signature}
          diagnosed_at: 2026-05-16T00:00:00Z
          ---
          # Red Status Diagnosis

          agent verdict
        MD
        { path: path, generated_by: "codex" }
      end

      out, = capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder, write: true).call
      end

      payload = JSON.parse(out)
      assert_equal "codex", payload.dig("diagnostic", "generated_by")
      assert_includes payload.dig("diagnostic", "detail"), "agent verdict"
      assert_equal File.join(folder, "diagnostics", "red-status.md"), payload["path"]
      assert seen_local_diagnostic
    ensure
      Hive::DiagnosisAgent.define_singleton_method(:run!, sentinel) if sentinel
    end
  end
end
