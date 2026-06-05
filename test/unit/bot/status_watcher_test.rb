require "test_helper"
require "json"
require "hive/bot/status_watcher"

class HiveBotStatusWatcherTest < Minitest::Test
  include HiveTestHelper

  CapturingLogger = Struct.new(:events, keyword_init: true) do
    def initialize(events: [])
      super
    end

    def event(name, **payload)
      events << { name: name, payload: payload }
    end
  end

  def with_fake_status(payload, exit_code: 0, stderr_text: "")
    with_tmp_dir do |dir|
      script = File.join(dir, "fake-hive")
      File.write(script, <<~RUBY)
        #!/usr/bin/env ruby
        if ARGV != %w[status --json]
          $stderr.puts "unexpected argv: \#{ARGV.inspect}"
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

  def envelope(tasks)
    {
      "schema" => "hive-status",
      "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
      "ok" => true,
      "generated_at" => Time.now.utc.iso8601,
      "projects" => [
        {
          "name" => "hive",
          "path" => "/tmp/hive",
          "hive_state_path" => "/tmp/hive/.hive-state",
          "tasks" => tasks
        }
      ]
    }
  end

  def task(slug:, marker: "waiting", attrs: {}, action: "needs_input")
    {
      "stage" => "2-brainstorm",
      "slug" => slug,
      "id" => 42,
      "display_name" => "Readable Row",
      "folder" => "/tmp/hive/.hive-state/stages/2-brainstorm/#{slug}",
      "state_file" => "/tmp/hive/.hive-state/stages/2-brainstorm/#{slug}/brainstorm.md",
      "marker" => marker,
      "attrs" => attrs,
      "mtime" => Time.now.utc.iso8601,
      "age_seconds" => 3,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => action,
      "action_label" => "Needs your input",
      "suggested_command" => "hive brainstorm #{slug} --from 2-brainstorm",
      "next_action" => nil,
      "diagnostic" => nil
    }
  end

  def test_fetch_parses_status_rows
    with_fake_status(JSON.generate(envelope([ task(slug: "s1") ]))) do |bin|
      result = Hive::Bot::StatusWatcher.new(hive_bin: bin).fetch

      assert result.ok, result.error
      assert_equal 1, result.rows.size
      row = result.rows.first
      assert_equal "hive", row.project
      assert_equal "s1", row.slug
      assert_equal 42, row.id
      assert_equal "Readable Row", row.display_name
      assert_equal "waiting", row.marker
      assert_equal "needs_input", row.action
      assert_nil row.diagnostic
    end
  end

  def test_tick_fetches_status_rows
    with_fake_status(JSON.generate(envelope([ task(slug: "tick-task") ]))) do |bin|
      result = Hive::Bot::StatusWatcher.new(hive_bin: bin).tick(now: Time.utc(2026, 1, 1))

      assert result.ok, result.error
      assert_equal [ "tick-task" ], result.rows.map(&:slug)
    end
  end

  def test_fetch_exposes_legacy_stage_dirs_for_transition_notifications
    payload = envelope([])
    project = payload.fetch("projects").first
    project["legacy_stage_dirs"] = [
      { "stage_dir" => "5-review", "task_count" => 2 },
      { "stage_dir" => "6-pr", "task_count" => 1 }
    ]
    project["legacy_migrate_command"] = "hive migrate"

    with_fake_status(JSON.generate(payload)) do |bin|
      result = Hive::Bot::StatusWatcher.new(hive_bin: bin).fetch

      assert result.ok, result.error
      legacy = result.legacy_stage_dirs
      assert_equal 1, legacy.size
      entry = legacy.first
      assert_equal "hive", entry.project
      assert_equal "/tmp/hive", entry.project_path
      assert_equal "/tmp/hive/.hive-state", entry.hive_state_path
      assert_equal [ "5-review", "6-pr" ], entry.stage_dir_names
      assert_equal 3, entry.total_task_count
      assert_equal "hive migrate", entry.legacy_migrate_command
      assert_equal "legacy_stage_dirs", entry.action
    end
  end

  def test_fetch_skips_missing_empty_and_project_error_legacy_stage_dirs
    payload = envelope([])
    payload.fetch("projects").first.delete("legacy_stage_dirs")
    payload["projects"] << {
      "name" => "clean",
      "path" => "/tmp/clean",
      "hive_state_path" => "/tmp/clean/.hive-state",
      "tasks" => [],
      "legacy_stage_dirs" => [],
      "legacy_migrate_command" => nil
    }
    payload["projects"] << {
      "name" => "broken",
      "path" => "/tmp/broken",
      "hive_state_path" => "/tmp/broken/.hive-state",
      "error" => "not_initialised",
      "tasks" => [],
      "legacy_stage_dirs" => [ { "stage_dir" => "5-review", "task_count" => 1 } ],
      "legacy_migrate_command" => "hive migrate"
    }

    with_fake_status(JSON.generate(payload)) do |bin|
      result = Hive::Bot::StatusWatcher.new(hive_bin: bin).fetch

      assert result.ok, result.error
      assert_empty result.legacy_stage_dirs
    end
  end

  def test_fetch_logs_nonzero_status_failure
    logger = CapturingLogger.new

    with_fake_status("", exit_code: 2, stderr_text: "boom\n") do |bin|
      result = Hive::Bot::StatusWatcher.new(hive_bin: bin, logger: logger).fetch

      refute result.ok
      assert_match(/exited 2/, result.error)
      assert_equal :poll_failure, logger.events.first.fetch(:name)
      assert_equal "status", logger.events.first.fetch(:payload).fetch(:source)
    end
  end

  def test_fetch_rejects_invalid_envelopes
    expected_version = Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status")
    cases = {
      "wrong schema" => [ { "schema" => "other", "ok" => true, "schema_version" => expected_version }, /missing schema/ ],
      "not ok" => [ { "schema" => "hive-status", "ok" => false, "schema_version" => expected_version,
                       "message" => "registry unavailable" }, /envelope ok=false: registry unavailable/ ],
      "wrong version" => [ { "schema" => "hive-status", "ok" => true, "schema_version" => -1 }, /schema_version mismatch/ ]
    }

    cases.each do |label, (payload, pattern)|
      with_fake_status(JSON.generate(payload)) do |bin|
        logger = CapturingLogger.new
        result = Hive::Bot::StatusWatcher.new(hive_bin: bin, logger: logger).fetch

        refute result.ok, label
        assert_match pattern, result.error, label
        assert_equal :poll_failure, logger.events.first.fetch(:name), label
      end
    end
  end

  def test_fetch_skips_project_errors_and_uses_mtime_fallbacks
    with_tmp_dir do |dir|
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      file_time = Time.utc(2026, 1, 1, 10, 0, 0)
      state_file = File.join(dir, "brainstorm.md")
      File.write(state_file, "state")
      File.utime(file_time, file_time, state_file)
      file_task = task(slug: "file-mtime").merge("mtime" => "", "state_file" => state_file)
      fallback_task = task(slug: "fallback-mtime").merge(
        "mtime" => "not-a-time",
        "state_file" => File.join(dir, "missing.md")
      )
      payload = envelope([ file_task, fallback_task ])
      payload["projects"] << {
        "name" => "broken",
        "path" => "/tmp/broken",
        "hive_state_path" => "/tmp/broken/.hive-state",
        "error" => "unreadable",
        "tasks" => [ task(slug: "skip-me") ]
      }

      with_fake_status(JSON.generate(payload)) do |bin|
        result = Hive::Bot::StatusWatcher.new(hive_bin: bin).fetch(now: now)

        assert result.ok, result.error
        assert_equal [ "file-mtime", "fallback-mtime" ], result.rows.map(&:slug)
        assert_equal file_time.to_i, result.rows.first.state_file_mtime.to_i
        assert_equal now, result.rows.last.state_file_mtime
      end
    end
  end

  def test_fetch_returns_not_ok_on_nonzero_status
    with_fake_status("", exit_code: 1, stderr_text: "boom\n") do |bin|
      result = Hive::Bot::StatusWatcher.new(hive_bin: bin).fetch

      refute result.ok
      assert_match(/exited 1/, result.error)
    end
  end

  def test_fetch_returns_not_ok_on_malformed_json
    with_fake_status("not-json") do |bin|
      result = Hive::Bot::StatusWatcher.new(hive_bin: bin).fetch

      refute result.ok
      assert_match(/malformed JSON/, result.error)
    end
  end
end
