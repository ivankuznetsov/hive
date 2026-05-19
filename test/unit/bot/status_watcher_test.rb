require "test_helper"
require "json"
require "hive/bot/status_watcher"

class HiveBotStatusWatcherTest < Minitest::Test
  include HiveTestHelper

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
      assert_equal "waiting", row.marker
      assert_equal "needs_input", row.action
      assert_nil row.diagnostic
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
