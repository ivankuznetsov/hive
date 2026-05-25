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
      "suggested_command" => command
    }
  end

  # ── happy path ────────────────────────────────────────────────────────

  def test_parses_envelope_into_rows
    payload = make_envelope(projects: [ {
      "name" => "writero",
      "path" => "/tmp/writero",
      "hive_state_path" => "/tmp/writero/.hive-state",
      "tasks" => [ task_row(slug: "fix-bug") ]
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
    end
  end

  # Issue #144: the daemon healer and dispatcher use `row.live_task_lock`
  # to recognise a live `hive run` during the pre-claude_pid window. Pin
  # the parse of the JSON key here so a regression in `task_payload`
  # (Hive::Commands::Status) or the Row struct surfaces as a structured
  # test failure rather than a silent classification change downstream.
  def test_parses_live_task_lock_field_and_coerces_to_strict_boolean
    task_true = task_row(slug: "live-runner").merge("live_task_lock" => true)
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
      assert_equal false, rows.fetch("no-runner").live_task_lock,
                   "explicit false must propagate"
      assert_equal false, rows.fetch("legacy-payload").live_task_lock,
                   "missing key must coerce to false, not nil — downstream callers compare with ==true"
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

  def test_schema_version_mismatch_returns_not_ok
    payload = make_envelope.merge("schema_version" => 99)
    with_fake_status(JSON.generate(payload)) do |bin|
      consumer = Hive::Daemon::StatusConsumer.new(hive_bin: bin)
      result = consumer.fetch
      refute result.ok
      assert_match(/schema_version mismatch/, result.error)
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
