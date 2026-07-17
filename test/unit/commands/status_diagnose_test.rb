require "test_helper"
require "digest"
require "fileutils"
require "json"
require "json_schemer"
require "tmpdir"
require "hive/commands/status"
require "hive/diagnosis_agent"
require "hive/task_meta"

class StatusDiagnoseTest < Minitest::Test
  # Validate a real --diagnose envelope against the published schema. The
  # evidence (nil-diagnostic) branch hand-assembles the schema-governed
  # Diagnostic shape in Hive::Commands::Status#evidence_diagnostic; without a
  # JSONSchemer round-trip on the actual producer, a field added to
  # Diagnostic#to_h + the schema would leave this branch emitting an invalid
  # envelope (additionalProperties:false, the source/generated_by enums, the
  # summary/detail maxLengths) and ship silently.
  def assert_diagnose_envelope_valid(payload)
    schemer = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-status-diagnose")))
    )
    errors = schemer.validate(payload).map { |e| e["error"] }
    assert_empty errors, "evidence diagnose envelope must validate (errors: #{errors.inspect})"
  end

  def with_review_task
    Dir.mktmpdir("hive-status-diagnose") do |project_root|
      slug = "red-task-260516-aaaa"
      folder = File.join(project_root, ".hive-state", "stages", "6-review", slug)
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      Hive::TaskMeta.write(folder, id: 42, slug: slug, display_name: "Red Task")
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
      assert_equal 42, payload["id"]
      assert_equal "Red Task", payload["display_name"]
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

  def test_diagnose_json_emits_evidence_diagnostic_for_non_red_task_with_logs
    Dir.mktmpdir("hive-status-diagnose-evidence") do |project_root|
      slug = "rotated-task-260628-abcd"
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", slug)
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      state_file = File.join(folder, "plan.md")
      log_path = File.join(logs, "plan.log")
      File.write(state_file, "<!-- COMPLETE -->\n")
      File.write(log_path, "working\nlast useful failure\n")

      out, = capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder).call
      end

      payload = JSON.parse(out)
      assert_equal "COMPLETE", payload["marker_summary"]
      assert_kind_of Hash, payload["diagnostic"]
      assert_equal "COMPLETE: last useful failure", payload.dig("diagnostic", "summary")
      assert_equal "Log: #{log_path}", payload.dig("diagnostic", "detail")
      assert_equal "artifact", payload.dig("diagnostic", "source")
      assert_equal log_path, payload.dig("diagnostic", "source_path")
      assert_equal [ log_path ], payload.dig("diagnostic", "artifact_paths")
      assert_diagnose_envelope_valid(payload)
    end
  end

  def test_diagnose_json_evidence_marker_tier_payload_and_schema
    Dir.mktmpdir("hive-status-diagnose-marker") do |project_root|
      slug = "rotated-task-260628-mkr0"
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", slug)
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "plan.md")
      # A non-red marker with no red-status and no log → marker-tier evidence.
      File.write(state_file, "<!-- COMPLETE -->\n")

      out, = capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder).call
      end

      payload = JSON.parse(out)
      assert_equal "COMPLETE", payload.dig("diagnostic", "summary")
      assert_equal "marker", payload.dig("diagnostic", "source")
      # The state file is labelled Marker:, not Log:.
      assert_equal "Marker: #{state_file}", payload.dig("diagnostic", "detail")
      assert_equal state_file, payload.dig("diagnostic", "source_path")
      assert_equal [], payload.dig("diagnostic", "artifact_paths")
      assert_diagnose_envelope_valid(payload)
    end
  end

  def test_diagnose_json_evidence_red_status_tier_uses_diagnostics_prefix
    Dir.mktmpdir("hive-status-diagnose-redstatus") do |project_root|
      slug = "rotated-task-260628-rst0"
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", slug)
      FileUtils.mkdir_p(File.join(folder, "diagnostics"))
      File.write(File.join(folder, "plan.md"), "<!-- COMPLETE -->\n")
      red_status = File.join(folder, "diagnostics", "red-status.md")
      File.write(red_status, <<~MD)
        ---
        summary: Cached agent verdict
        generated_by: codex
        ---
        body ignored
      MD

      out, = capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder).call
      end

      payload = JSON.parse(out)
      assert_equal "Cached agent verdict", payload.dig("diagnostic", "summary")
      assert_equal "artifact", payload.dig("diagnostic", "source")
      # A diagnostic artifact, labelled Diagnostics:, not Log:.
      assert_equal "Diagnostics: #{red_status}", payload.dig("diagnostic", "detail")
      assert_equal [ red_status ], payload.dig("diagnostic", "artifact_paths")
      assert_diagnose_envelope_valid(payload)
    end
  end

  def test_diagnose_json_markerless_task_emits_null_marker_summary
    # A markerless folder with no red-status/log evidence: marker_summary must
    # serialize as null (not "NONE") end-to-end and the diagnostic stays null.
    Dir.mktmpdir("hive-status-diagnose-null") do |project_root|
      slug = "markerless-task-260628-null"
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", slug)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "plan.md"), "plan body, no marker\n")

      out, = capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder).call
      end

      payload = JSON.parse(out)
      assert payload.key?("marker_summary")
      assert_nil payload["marker_summary"]
      assert_nil payload["diagnostic"]
      assert_diagnose_envelope_valid(payload)
    end
  end

  def test_diagnose_human_output_prints_evidence_for_non_red_task_with_logs
    Dir.mktmpdir("hive-status-diagnose-evidence") do |project_root|
      slug = "rotated-task-260628-abcd"
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", slug)
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      log_path = File.join(logs, "plan.log")
      File.write(File.join(folder, "plan.md"), "<!-- COMPLETE -->\n")
      File.write(log_path, "last useful failure\n")

      out, = capture_io do
        Hive::Commands::Status.new(diagnose: folder).call
      end

      assert_includes out, "COMPLETE: last useful failure"
      assert_includes out, "Log: #{log_path}"
      refute_includes out, "no red-status diagnostic"
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
    previous_hive_home = ENV["HIVE_HOME"]
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
      previous_hive_home.nil? ? ENV.delete("HIVE_HOME") : ENV["HIVE_HOME"] = previous_hive_home
    end
  end

  def test_diagnose_slug_not_found_error_envelope_kind
    # An unresolvable bare slug raises Hive::InvalidTaskPath. The
    # diagnose error_kind enum maps InvalidTaskPath to "slug_not_found"
    # so agent callers can branch on "the task no longer exists"
    # without parsing error messages.
    previous_hive_home = ENV["HIVE_HOME"]
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
      previous_hive_home.nil? ? ENV.delete("HIVE_HOME") : ENV["HIVE_HOME"] = previous_hive_home
    end
  end

  # The JSONSchemer round-trips catch a REQUIRED-key drift between
  # evidence_diagnostic and the canonical Diagnostic#to_h, but NOT an OPTIONAL
  # one — a future optional Diagnostic key would be silently omitted on the
  # evidence path while the canonical path emits it. Assert the two key sets
  # are identical so that gap is closed.
  def test_evidence_diagnostic_key_set_matches_canonical_to_h
    Dir.mktmpdir("hive-status-diagnose-parity") do |project_root|
      # Canonical (production) Diagnostic#to_h from a red task.
      red_slug = "red-task-260628-aaaa"
      red_folder = File.join(project_root, ".hive-state", "stages", "6-review", red_slug)
      FileUtils.mkdir_p(File.join(red_folder, "reviews"))
      File.write(File.join(red_folder, "task.md"), "<!-- REVIEW_ERROR phase=fix pass=1 -->\n")
      File.write(File.join(red_folder, "reviews", "errors-01.md"), "fix failed\n")
      red_task = Hive::Task.new(red_folder)
      red_marker = Hive::Markers.current(red_task.state_file)
      canonical = Hive::TaskAction.for(red_task, red_marker).diagnostic
      refute_nil canonical, "fixture must produce a canonical production diagnostic"

      # Evidence (fallback) shape from a non-red task's marker tier.
      ev_slug = "green-task-260628-bbbb"
      ev_folder = File.join(project_root, ".hive-state", "stages", "3-plan", ev_slug)
      FileUtils.mkdir_p(ev_folder)
      File.write(File.join(ev_folder, "plan.md"), "<!-- COMPLETE -->\n")
      ev_task = Hive::Task.new(ev_folder)
      ev_marker = Hive::Markers.current(ev_task.state_file)
      evidence = Hive::DiagnosticEvidence.summarize(
        folder: ev_folder, marker_summary: "COMPLETE", state_file: ev_task.state_file
      )
      refute_nil evidence
      evidence_shape = Hive::Commands::Status.new.send(:evidence_diagnostic, ev_task, ev_marker, evidence)

      assert_equal canonical.keys.sort, evidence_shape.keys.sort,
                   "evidence_diagnostic must emit the same key set as Diagnostic#to_h " \
                   "(optional-key drift the schema round-trip misses)"
    end
  end

  # No existing round-trip forces an evidence summary at exactly the schema's
  # 120-char cap (truncate emits 119 chars + "…" = 120 code points). Pin the
  # boundary so a counting-semantics drift (bytes vs code points) is caught.
  def test_diagnose_evidence_summary_at_120_char_cap_validates
    Dir.mktmpdir("hive-status-diagnose-capped") do |project_root|
      slug = "rotated-task-260628-cap0"
      folder = File.join(project_root, ".hive-state", "stages", "3-plan", slug)
      logs = File.join(folder, "logs")
      FileUtils.mkdir_p(logs)
      File.write(File.join(folder, "plan.md"), "<!-- COMPLETE -->\n")
      # "COMPLETE: <200 x's>" comfortably exceeds 120 chars, so the summary is
      # truncated to exactly the cap.
      File.write(File.join(logs, "plan.log"), "#{'x' * 200}\n")

      out, = capture_io do
        Hive::Commands::Status.new(json: true, diagnose: folder).call
      end

      payload = JSON.parse(out)
      summary = payload.dig("diagnostic", "summary")
      assert_equal 120, summary.length,
                   "evidence summary must sit exactly at the 120-code-point cap"
      assert summary.end_with?("…")
      assert_diagnose_envelope_valid(payload)
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
