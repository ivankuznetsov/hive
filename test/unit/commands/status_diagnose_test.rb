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

  # Run the given diagnose invocation expecting `err_class`; capture
  # the JSON envelope written to stdout BEFORE the exception propagates
  # so the test can assert on both the exit code and the envelope
  # `error_kind`. Without this helper, the `capture_io do ... end`
  # block inside `assert_raises` swallows stdout when the body raises.
  def capture_diagnose_error(err_class, **kwargs)
    out_buf = ""
    err = nil
    captured = capture_io do
      Hive::Commands::Status.new(**kwargs).call
    rescue err_class => e
      err = e
    end
    out_buf = captured.first
    [ err, out_buf ]
  end

  def test_diagnose_stale_marker_error_envelope_exit_code_and_kind
    # StaleMarker is retryable — agent wrappers branch on TEMPFAIL (75)
    # to re-issue, vs SOFTWARE (70) to escalate. The envelope's
    # error_kind must surface the structured "stale_marker" value, not
    # the generic "error" fallback. See PR #84 review row 4.
    with_review_task do |folder, _slug|
      sentinel = Hive::DiagnosisAgent.method(:run!)
      Hive::DiagnosisAgent.define_singleton_method(:run!) do |**_kwargs|
        raise Hive::DiagnosisAgent::StaleMarker, "marker rotated"
      end

      err, out = capture_diagnose_error(
        Hive::DiagnosisAgent::StaleMarker,
        json: true, diagnose: folder, write: true
      )
      refute_nil err, "StaleMarker must propagate from #call"
      assert_equal Hive::ExitCodes::TEMPFAIL, err.exit_code,
                   "StaleMarker must surface exit_code=TEMPFAIL (75) so wrappers retry"
      payload = JSON.parse(out)
      assert_equal false, payload["ok"]
      assert_equal "stale_marker", payload["error_kind"]
      assert_equal Hive::ExitCodes::TEMPFAIL, payload["exit_code"]
    ensure
      Hive::DiagnosisAgent.define_singleton_method(:run!, sentinel) if sentinel
    end
  end

  def test_diagnose_in_flight_error_envelope_exit_code_and_kind
    # DiagnosisInFlight is the per-task flock collision (parallel
    # --diagnose --write). Retryable; same TEMPFAIL contract as
    # StaleMarker so wrappers can branch uniformly on exit code.
    with_review_task do |folder, _slug|
      sentinel = Hive::DiagnosisAgent.method(:run!)
      Hive::DiagnosisAgent.define_singleton_method(:run!) do |**_kwargs|
        raise Hive::DiagnosisAgent::DiagnosisInFlight, "another diagnose holds the lock"
      end

      err, out = capture_diagnose_error(
        Hive::DiagnosisAgent::DiagnosisInFlight,
        json: true, diagnose: folder, write: true
      )
      refute_nil err
      assert_equal Hive::ExitCodes::TEMPFAIL, err.exit_code
      payload = JSON.parse(out)
      assert_equal false, payload["ok"]
      assert_equal "in_flight", payload["error_kind"]
      assert_equal Hive::ExitCodes::TEMPFAIL, payload["exit_code"]
    ensure
      Hive::DiagnosisAgent.define_singleton_method(:run!, sentinel) if sentinel
    end
  end

  def test_diagnose_ambiguous_slug_error_envelope_kind
    # AmbiguousSlug is a TaskResolver failure when a slug matches in
    # multiple registered projects. The diagnose-specific error_kind
    # enum surfaces "ambiguous_slug" so callers can disambiguate from a
    # true unknown slug ("slug_not_found"). See PR #84 review row 4.
    Dir.mktmpdir("hive-status-diagnose-ambig") do |home|
      project_a = File.join(home, "alpha")
      project_b = File.join(home, "beta")
      slug = "shared-slug-260518-abcd"
      [ project_a, project_b ].each do |root|
        folder = File.join(root, ".hive-state", "stages", "6-review", slug)
        FileUtils.mkdir_p(folder)
        File.write(File.join(folder, "task.md"), "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
      end
      File.write(
        File.join(home, "config.yml"),
        YAML.dump(
          "registered_projects" => [
            { "name" => "alpha", "path" => project_a },
            { "name" => "beta", "path" => project_b }
          ]
        )
      )

      ENV["HIVE_HOME"] = home
      err, out = capture_diagnose_error(
        Hive::AmbiguousSlug,
        json: true, diagnose: slug
      )
      refute_nil err, "AmbiguousSlug must propagate"
      assert_equal Hive::ExitCodes::USAGE, err.exit_code
      payload = JSON.parse(out)
      assert_equal false, payload["ok"]
      assert_equal "ambiguous_slug", payload["error_kind"]
    ensure
      ENV.delete("HIVE_HOME")
    end
  end

  def test_diagnose_slug_not_found_error_envelope_kind
    # An unresolvable bare slug raises Hive::InvalidTaskPath. The
    # diagnose error_kind enum maps InvalidTaskPath to "slug_not_found"
    # so agent callers can branch on "the task no longer exists"
    # without parsing error messages.
    Dir.mktmpdir("hive-status-diagnose-missing") do |home|
      File.write(File.join(home, "config.yml"), YAML.dump("registered_projects" => []))

      ENV["HIVE_HOME"] = home
      err, out = capture_diagnose_error(
        Hive::InvalidTaskPath,
        json: true, diagnose: "no-such-slug-260518-zzzz"
      )
      refute_nil err
      assert_equal Hive::ExitCodes::USAGE, err.exit_code
      payload = JSON.parse(out)
      assert_equal false, payload["ok"]
      assert_equal "slug_not_found", payload["error_kind"]
    ensure
      ENV.delete("HIVE_HOME")
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
