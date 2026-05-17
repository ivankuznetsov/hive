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

  def test_diagnose_write_on_green_task_refuses_to_burn_budget
    # Green/healthy tasks (no red marker) have nil diagnostic; spawning
    # the configured agent would burn LLM budget for no signal. Verify
    # the gate raises Hive::Error before any DiagnosisAgent spawn. See
    # PR #84 review finding #1.
    Dir.mktmpdir("hive-status-diagnose-green") do |project_root|
      slug = "green-task-260517-bbbb"
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "task.md"), "<!-- COMPLETE -->\n")

      sentinel = Hive::DiagnosisAgent.method(:run!)
      spawned = false
      Hive::DiagnosisAgent.define_singleton_method(:run!) do |**_kwargs|
        spawned = true
        { path: "should-not-reach-here", generated_by: "claude" }
      end

      error = assert_raises(Hive::Error) do
        capture_io { Hive::Commands::Status.new(diagnose: folder, write: true).call }
      end
      assert_match(/not in a red recovery state/, error.message)
      refute spawned, "DiagnosisAgent.run! must NOT be invoked on a green task"
    ensure
      Hive::DiagnosisAgent.define_singleton_method(:run!, sentinel) if sentinel
    end
  end

  def test_diagnose_write_short_circuits_when_fresh_artifact_already_present
    # When a previous agent run already wrote diagnostics/red-status.md
    # and its marker_signature matches the current marker, --write
    # must reuse it rather than re-spawning the agent. --force opts
    # back into a fresh spawn. See PR #84 review finding #21.
    with_review_task do |folder, _slug|
      marker_signature = Digest::SHA256.hexdigest("review_error\npass=1\nphase=fix")
      diagnostics_dir = File.join(folder, "diagnostics")
      FileUtils.mkdir_p(diagnostics_dir)
      File.write(File.join(diagnostics_dir, "red-status.md"), <<~MD)
        ---
        generated_by: claude
        marker_signature: #{marker_signature}
        diagnosed_at: 2026-05-16T00:00:00Z
        ---
        # Red Status Diagnosis

        prior agent verdict
      MD

      sentinel = Hive::DiagnosisAgent.method(:run!)
      spawn_count = 0
      Hive::DiagnosisAgent.define_singleton_method(:run!) do |**_kwargs|
        spawn_count += 1
        { path: File.join(diagnostics_dir, "red-status.md"), generated_by: "claude" }
      end

      # Without --force: short-circuit, no spawn.
      capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder, write: true).call
      end
      assert_equal 0, spawn_count,
                   "fresh artifact must short-circuit DiagnosisAgent.run!"

      # With --force: spawn regardless.
      capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder, write: true, force: true).call
      end
      assert_equal 1, spawn_count, "--force must bypass the short-circuit"
    ensure
      Hive::DiagnosisAgent.define_singleton_method(:run!, sentinel) if sentinel
    end
  end
end
