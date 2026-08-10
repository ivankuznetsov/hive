require "test_helper"
require "json"
require "tmpdir"
require "hive/daemon/status_consumer"

# Pin StatusConsumer's parsing of `hive status --json` output. We
# stand in a tiny ruby script that emits a controlled JSON envelope on
# stdout, since calling the real binary would couple this test to the
# whole status implementation.
class HiveDaemonStatusConsumerTest < Minitest::Test
  include HiveTestHelper

  def with_fake_status(payload, exit_code: 0, stderr_text: "")
    with_tmp_dir do |dir|
      script = File.join(dir, "fake-hive")
      File.write(script, <<~RUBY)
        #!/usr/bin/env ruby
        if ARGV != %w[status --json]
          $stderr.puts "fake-hive: unexpected argv #{ARGV.inspect}"
          exit 64
        end
        $stderr.write #{stderr_text.inspect}
        $stdout.write #{payload.inspect}
        exit #{exit_code}
      RUBY
      File.chmod(0o755, script)
      yield(script)
    end
  end

  def make_envelope(projects: [])
    {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS["hive-status"],
      "ok" => true,
      "generated_at" => Time.now.utc.iso8601,
      "projects" => projects
    }
  end

  def task_row(slug:, stage: "1-inbox", marker: "waiting",
               action: "ready_to_brainstorm", command: "hive brainstorm slug",
               mtime: Time.now.utc.iso8601)
    {
      "stage" => stage,
      "slug" => slug,
      "folder" => "/tmp/p/#{stage}/#{slug}",
      "state_file" => "/tmp/p/#{stage}/#{slug}/idea.md",
      "marker" => marker,
      "attrs" => {},
      "mtime" => mtime,
      "age_seconds" => 0,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => action,
      "action_label" => "Ready to brainstorm",
      "suggested_command" => command,
      "depends_on" => nil,
      "blocked_by" => nil,
      "dependency_stage" => nil,
      "blocked" => false,
      "admission_error" => nil
    }
  end

  # ── happy path ────────────────────────────────────────────────────────

  def test_parses_envelope_into_rows
    payload = make_envelope(projects: [ {
      "name" => "writero",
      "path" => "/tmp/writero",
      "hive_state_path" => "/tmp/writero/.hive-state",
      "hidden_archived_task_count" => 3,
      "tasks" => [
        task_row(slug: "fix-bug").merge(
          "pr_url" => "https://github.com/acme/writero/pull/42"
        )
      ]
    } ])
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      assert result.ok, "expected ok=true; got error #{result.error.inspect}"
      assert_equal 1, result.rows.size
      row = result.rows.first
      assert_equal "writero", row.project
      assert_equal "fix-bug", row.slug
      assert_equal "ready_to_brainstorm", row.action
      assert_equal "hive brainstorm slug", row.suggested_command
      assert_equal "https://github.com/acme/writero/pull/42", row.pr_url
      assert_equal 3, result.hidden_archived_task_count
      assert_equal 3, result.projects.first.hidden_archived_task_count
    end
  end

  def test_missing_hidden_archived_count_defaults_to_zero_but_invalid_values_fail
    legacy = make_envelope(projects: [ {
      "name" => "legacy", "path" => "/tmp/legacy", "hive_state_path" => "/tmp/legacy/.h",
      "tasks" => []
    } ])
    with_fake_status(JSON.generate(legacy)) do |bin|
      result = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch
      assert result.ok
      assert_equal 0, result.hidden_archived_task_count
      assert_equal 0, result.projects.first.hidden_archived_task_count
    end

    malformed = make_envelope(projects: [ {
      "name" => "bad", "path" => "/tmp/bad", "hive_state_path" => "/tmp/bad/.h",
      "hidden_archived_task_count" => -1, "tasks" => []
    } ])
    with_fake_status(JSON.generate(malformed)) do |bin|
      result = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch
      refute result.ok
      assert_match(/hidden_archived_task_count/, result.error)
    end
  end

  # Issue #144: the daemon healer and dispatcher use `row.live_task_lock`
  # to recognise a live `hive run` during the pre-claude_pid window. Pin
  # the parse of the JSON key here so a regression in `task_payload`
  # (Hive::Commands::Status) or the Row struct surfaces as a structured
  # test failure rather than a silent classification change downstream.
  def test_parses_live_task_lock_field_and_coerces_to_strict_boolean
    task_true = task_row(slug: "live-runner").merge(
      "live_task_lock" => true,
      "task_lock_pid" => 12_345,
      "task_lock_process_start_time" => "observed-start",
      "task_lock_id" => "observed-generation"
    )
    task_false = task_row(slug: "no-runner").merge("live_task_lock" => false)
    task_missing = task_row(slug: "legacy-payload")
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_true, task_false, task_missing ]
    } ])
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      assert result.ok
      rows = result.rows.each_with_object({}) { |r, h| h[r.slug] = r }
      assert_equal true, rows.fetch("live-runner").live_task_lock,
                   "explicit true must propagate"
      assert_equal 12_345, rows.fetch("live-runner").task_lock_pid
      assert_equal "observed-start", rows.fetch("live-runner").task_lock_process_start_time
      assert_equal "observed-generation", rows.fetch("live-runner").task_lock_id
      assert_equal false, rows.fetch("no-runner").live_task_lock,
                   "explicit false must propagate"
      assert_equal false, rows.fetch("legacy-payload").live_task_lock,
                   "missing key must coerce to false, not nil — downstream callers compare with ==true"
    end
  end

  def test_passes_through_canonical_condition_projection_fields
    condition = { "condition" => "ChangesPresent", "state" => "satisfied" }
    task = task_row(slug: "conditioned").merge(
      "condition_task_generation" => 3,
      "commit_generation" => 2,
      "current_attempt" => "attempt-b",
      "conditions" => [ condition ],
      "condition_history" => [ condition.merge("state" => "superseded") ],
      "evidence" => [ { "type" => "commit", "sha" => "b" * 40 } ],
      "condition_overrides" => [ {
        "reason" => "forced_condition_transition", "source_command" => "approve"
      } ],
      "condition_gate" => { "status" => "eligible" },
      "condition_migration" => { "effective" => "conditions" },
      "condition_provenance" => { "projector" => "TaskProjection/v1" },
      "shadow_audit" => { "ready" => false },
      "condition_warning" => nil
    )
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task ]
    } ])

    with_fake_status(JSON.generate(payload)) do |bin|
      row = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch.rows.fetch(0)
      assert_equal 3, row.condition_task_generation
      assert_equal 2, row.commit_generation
      assert_equal "attempt-b", row.current_attempt
      assert_equal [ condition ], row.conditions
      assert_equal "approve", row.condition_overrides.fetch(0).fetch("source_command")
      assert_equal "eligible", row.condition_gate.fetch("status")
      assert_equal "conditions", row.condition_migration.fetch("effective")
    end
  end

  def test_parses_dependency_fields_and_coerces_blocked_to_boolean
    task_blocked = task_row(slug: "dependent").merge(
      "depends_on" => "base",
      "blocked_by" => "base",
      "dependency_stage" => "7-artifacts",
      "blocked" => true
    )
    task_missing = task_row(slug: "legacy-payload")
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_blocked, task_missing ]
    } ])

    with_fake_status(JSON.generate(payload)) do |bin|
      result = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch

      assert result.ok
      rows = result.rows.each_with_object({}) { |row, hash| hash[row.slug] = row }
      dependent = rows.fetch("dependent")
      assert_equal "base", dependent.depends_on
      assert_equal "base", dependent.blocked_by
      assert_equal "7-artifacts", dependent.dependency_stage
      assert_equal true, dependent.blocked
      assert_equal false, rows.fetch("legacy-payload").blocked
    end
  end

  def test_parses_admission_error_and_forces_inert_row_shape
    admission = {
      "reason_code" => "dependency_cycle",
      "offending_ref" => "p:a -> p:b -> p:a",
      "safe_correction" => "Break the cycle."
    }
    task = task_row(slug: "held", action: "ready_to_archive", command: "hive archive held").merge(
      "blocked" => false,
      "admission_error" => admission
    )
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task ]
    } ])

    with_fake_status(JSON.generate(payload)) do |bin|
      row = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch.rows.first

      assert_equal true, row.blocked
      assert_equal "admission_error", row.action
      assert_nil row.suggested_command
      assert_equal "dependency_cycle", row.admission_error.reason_code
      assert_equal "Break the cycle.", row.admission_error.safe_correction
    end
  end

  def test_missing_admission_field_fails_closed_even_on_known_action
    task = task_row(slug: "schema-drift")
    task.delete("admission_error")
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task ]
    } ])

    with_fake_status(JSON.generate(payload)) do |bin|
      row = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch.rows.first

      assert_equal true, row.blocked
      assert_equal "admission_error", row.action
      assert_equal "dependency_validation_failed", row.admission_error.reason_code
    end
  end

  def test_malformed_admission_objects_fail_closed_per_row
    malformed = [
      "not-an-object",
      { "reason_code" => "dependency_cycle", "offending_ref" => "p:a" },
      { "reason_code" => "unknown", "offending_ref" => "p:a", "safe_correction" => "Fix it." },
      { "reason_code" => "dependency_cycle", "offending_ref" => "", "safe_correction" => "Fix it." },
      {
        "reason_code" => "dependency_cycle", "offending_ref" => "p:a",
        "safe_correction" => "Fix it.", "extra" => true
      }
    ]
    tasks = malformed.each_with_index.map do |value, index|
      task_row(slug: "malformed-#{index}").merge("admission_error" => value)
    end
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => tasks
    } ])

    with_fake_status(JSON.generate(payload)) do |bin|
      rows = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch.rows

      assert_equal malformed.size, rows.size
      rows.each do |row|
        assert_equal true, row.blocked
        assert_equal "admission_error", row.action
        assert_nil row.suggested_command
        assert_equal "dependency_validation_failed", row.admission_error.reason_code
      end
    end
  end

  def test_parses_multiple_projects_and_tasks
    payload = make_envelope(projects: [
      {
        "name" => "p1", "path" => "/tmp/p1", "hive_state_path" => "/tmp/p1/.h",
        "tasks" => [
          task_row(slug: "s1", action: "ready_to_brainstorm"),
          task_row(slug: "s2", action: "needs_input", marker: "waiting")
        ]
      },
      {
        "name" => "p2", "path" => "/tmp/p2", "hive_state_path" => "/tmp/p2/.h",
        "tasks" => [ task_row(slug: "s3", action: "ready_to_archive",
                              command: "hive archive s3 --from 8-finalize") ]
      }
    ])
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      assert result.ok
      assert_equal 3, result.rows.size
      slugs = result.rows.map(&:slug).sort
      assert_equal %w[s1 s2 s3], slugs
    end
  end

  def test_empty_projects_returns_empty_rows
    payload = make_envelope(projects: [])
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      assert result.ok
      assert_equal [], result.rows
    end
  end

  def test_skips_projects_with_error_field
    # `hive status --json` emits `error: "missing_project_path"` for
    # projects whose registered path is gone. Daemon must skip those —
    # the project is unrunnable until the operator re-registers.
    payload = make_envelope(projects: [
      { "name" => "missing", "path" => "/nope", "error" => "missing_project_path", "tasks" => [] },
      { "name" => "ok", "path" => "/tmp/ok", "hive_state_path" => "/tmp/ok/.h",
        "tasks" => [ task_row(slug: "s1") ] }
    ])
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      assert result.ok
      assert_equal 1, result.rows.size
      assert_equal "ok", result.rows.first.project
    end
  end

  def test_invalid_row_mtime_falls_back_to_state_file_mtime
    with_tmp_dir do |dir|
      state_file = File.join(dir, "idea.md")
      File.write(state_file, "<!-- WAITING -->\n")
      expected = File.mtime(state_file)

      task = task_row(slug: "mtime-fallback", mtime: "not-a-time")
      task["state_file"] = state_file
      payload = make_envelope(projects: [ {
        "name" => "writero",
        "path" => dir,
        "hive_state_path" => File.join(dir, ".hive-state"),
        "tasks" => [ task ]
      } ])

      with_fake_status(JSON.generate(payload)) do |bin|
        consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
        result = consumer.fetch

        assert result.ok, "expected ok=true; got error #{result.error.inspect}"
        assert_in_delta expected.to_f, result.rows.first.state_file_mtime.to_f, 0.001
      end
    end
  end

  def test_invalid_row_mtime_without_state_file_returns_nil
    task = task_row(slug: "missing-mtime", mtime: "not-a-time")
    task["state_file"] = "/tmp/hive-status-consumer-missing-state-file.md"
    payload = make_envelope(projects: [ {
      "name" => "writero",
      "path" => "/tmp/writero",
      "hive_state_path" => "/tmp/writero/.hive-state",
      "tasks" => [ task ]
    } ])

    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch

      assert result.ok, "expected ok=true; got error #{result.error.inspect}"
      assert_nil result.rows.first.state_file_mtime
    end
  end

  def test_valid_row_mtime_prefers_state_file_precision
    with_tmp_dir do |dir|
      state_file = File.join(dir, "idea.md")
      File.write(state_file, "<!-- WAITING -->\n")
      expected = Time.at(1_800_000_000, 456_789, :microsecond).utc
      File.utime(expected, expected, state_file)

      task = task_row(slug: "precise-mtime", mtime: expected.utc.iso8601)
      task["state_file"] = state_file
      payload = make_envelope(projects: [ {
        "name" => "writero",
        "path" => dir,
        "hive_state_path" => File.join(dir, ".hive-state"),
        "tasks" => [ task ]
      } ])

      with_fake_status(JSON.generate(payload)) do |bin|
        consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
        result = consumer.fetch

        assert result.ok, "expected ok=true; got error #{result.error.inspect}"
        assert_in_delta expected.to_f, result.rows.first.state_file_mtime.to_f, 0.001
        assert_operator result.rows.first.state_file_mtime.to_f, :>, Time.parse(task.fetch("mtime")).to_f
      end
    end
  end

  # ── failure modes ─────────────────────────────────────────────────────

  def test_non_zero_exit_returns_not_ok
    with_fake_status("", exit_code: 1, stderr_text: "boom\n") do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/exited 1/, result.error)
    end
  end

  def test_malformed_json_returns_not_ok
    with_fake_status("not json at all") do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/malformed JSON/, result.error)
    end
  end

  def test_wrong_schema_returns_not_ok
    payload = { "schema" => "hive-something-else", "schema_version" => 1, "ok" => true }
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/missing schema=hive-status/, result.error)
    end
  end

  # ── schema_version skew (forward-tolerant; must never crash a tick) ────

  # A NEWER envelope (expected+1) from an updated `hive` binary that the
  # long-running daemon hasn't restarted to match. hive-status envelopes
  # are additive, so rows still parse — the daemon keeps dispatching and
  # surfaces a non-fatal `warning` the dispatcher logs once per tick.
  def test_newer_schema_version_parses_best_effort_with_warning
    expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_row(slug: "newer") ]
    } ]).merge("schema_version" => expected + 1)

    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      assert result.ok, "newer schema must parse best-effort: #{result.error.inspect}"
      assert_equal [ "newer" ], result.rows.map(&:slug)
      refute_nil result.warning, "expected a best-effort skew warning"
      assert_match(/newer than this process/, result.warning)
      assert_match(/restart the hive daemon/i, result.warning)
    end
  end

  # An OLDER envelope (expected-1): a stale `hive` binary on PATH. The
  # daemon refuses to advance on untrustworthy data and surfaces a clear,
  # actionable message instead of crashing the tick.
  def test_older_schema_version_returns_actionable_failure
    expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
    payload = make_envelope.merge("schema_version" => expected - 1)
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/older than this process/, result.error)
      assert_match(/update\/reinstall the hive binary/, result.error)
    end
  end

  # A NEWER envelope whose best-effort extraction still throws degrades to
  # the actionable restart message instead of crashing the tick — AND
  # preserves the underlying exception in the surfaced error so a genuine
  # extraction bug, falsely presenting as a version skew, stays diagnosable.
  def test_newer_schema_failing_extraction_degrades_to_restart_message
    expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
    # A non-Hash project entry makes extract_rows raise (Integer#[] with a
    # String key), exercising the newer-skew rescue path.
    payload = make_envelope(projects: [ 42 ]).merge("schema_version" => expected + 1)
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok, "a newer payload that fails extraction must surface a failure, not raise"
      assert_match(/restart the hive daemon to pick up the new version/i, result.error)
      assert_match(/underlying error: TypeError:/, result.error,
                   "the real exception must be preserved in the surfaced error, not swallowed")
    end
  end

  # An EXACT/equal-version envelope whose extraction throws is NOT a skew —
  # it must surface the raw "#{e.class}: ..." line, never the friendly
  # restart hint (which would mislead an operator into a no-op restart).
  def test_exact_schema_failing_extraction_surfaces_raw_error_not_skew_hint
    payload = make_envelope(projects: [ 42 ])
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/TypeError:/, result.error)
      refute_match(/restart the hive daemon/i, result.error,
                   "an exact-version extraction bug must not be relabeled a version skew")
    end
  end

  # FINDING 1(b): a NEWER envelope that ALSO fails validate (ok=false) must
  # surface the REAL ok=false reason, never the skew restart hint.
  def test_newer_schema_with_ok_false_surfaces_real_reason_not_skew_hint
    expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
    payload = {
      "schema" => "hive-status",
      "schema_version" => expected + 1,
      "ok" => false,
      "error_class" => "ConfigError",
      "message" => "bad config"
    }
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/envelope ok=false: ConfigError bad config/, result.error,
                   "the real ok=false reason must surface even on a newer-schema doc")
      refute_match(/restart the hive daemon to pick up the new version/i, result.error,
                   "an ok=false envelope must NOT be relabeled as a version skew")
    end
  end

  # Exact match keeps the pre-existing happy path: ok, no warning.
  def test_exact_schema_version_match_has_no_warning
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_row(slug: "exact") ]
    } ])
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      assert result.ok, result.error
      assert_equal [ "exact" ], result.rows.map(&:slug)
      assert_nil result.warning, "exact-match fetch must not carry a skew warning"
    end
  end

  # A successful (exit-0) fetch whose stderr is non-empty carries the status
  # command's own degradation breadcrumbs (fail-open dependency gate, dropped
  # depends_on). Surface them via the warning channel so the dispatcher logs
  # them once per tick instead of discarding them.
  def test_successful_fetch_surfaces_nonempty_stderr_as_warning
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_row(slug: "s1") ]
    } ])
    breadcrumb = "hive: status: dependency resolve failed for \"dep\"; treating as unblocked\n"
    with_fake_status(JSON.generate(payload), stderr_text: breadcrumb) do |bin|
      result = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch
      assert result.ok, "non-empty stderr on an exit-0 fetch must not fail the result: #{result.error.inspect}"
      assert_equal [ "s1" ], result.rows.map(&:slug)
      refute_nil result.warning, "non-empty stderr on a healthy fetch must surface as a warning"
      assert_match(/treating as unblocked/, result.warning)
    end
  end

  # Forward skew AND non-empty stderr coexist: the single warning channel
  # must carry both advisories, not drop one for the other.
  def test_successful_fetch_combines_skew_and_stderr_warnings
    expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
    payload = make_envelope(projects: [ {
      "name" => "p", "path" => "/tmp/p", "hive_state_path" => "/tmp/p/.h",
      "tasks" => [ task_row(slug: "s1") ]
    } ]).merge("schema_version" => expected + 1)
    with_fake_status(JSON.generate(payload), stderr_text: "depends_on dropped\n") do |bin|
      result = Hive::Daemon::StatusConsumer.new(hive_bin: bin).fetch
      assert result.ok, result.error
      assert_match(/newer than this process/, result.warning)
      assert_match(/depends_on dropped/, result.warning)
    end
  end

  def test_envelope_with_ok_false_returns_not_ok
    payload = {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS["hive-status"],
      "ok" => false,
      "error_class" => "ConfigError",
      "message" => "bad config"
    }
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/envelope ok=false/, result.error)
    end
  end
end
