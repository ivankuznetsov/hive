require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/metrics"

# End-to-end coverage for `hive metrics rollback-rate`. Drives the
# command class directly (no Thor shell) and asserts both the
# human-readable text output and the --json payload schema.
class MetricsCommandTest < Minitest::Test
  include HiveTestHelper

  def commit_trailered(dir, file:, subject:, trailers: {})
    File.write(File.join(dir, file), File.exist?(File.join(dir, file)) ? "next\n" : "first\n")
    run!("git", "-C", dir, "add", file)
    body = trailers.map { |k, v| "#{k}: #{v}" }.join("\n")
    msg = body.empty? ? subject : "#{subject}\n\n#{body}\n"
    run!("git", "-C", dir, "commit", "-m", msg, "--quiet")
  end

  def with_registered_project
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        yield(dir, File.basename(dir))
      end
    end
  end

  def test_rollback_rate_text_output_with_zero_fix_commits
    with_registered_project do |_dir, _project|
      out, _err = capture_io { Hive::Commands::Metrics.new("rollback-rate").call }
      assert_match(/total fix commits: 0/, out)
      assert_match(/rate: *0\.00%/, out)
    end
  end

  def test_rollback_rate_json_schema
    with_registered_project do |dir, project|
      commit_trailered(dir, file: "a.rb", subject: "fix(a): one",
                       trailers: { "Hive-Fix-Pass" => "01", "Hive-Triage-Bias" => "courageous", "Hive-Fix-Phase" => "fix" })
      commit_trailered(dir, file: "b.rb", subject: "fix(b): two",
                       trailers: { "Hive-Fix-Pass" => "02", "Hive-Triage-Bias" => "safetyist", "Hive-Fix-Phase" => "fix" })

      out, _err = capture_io { Hive::Commands::Metrics.new("rollback-rate", json: true).call }
      payload = JSON.parse(out)
      assert_equal "hive-metrics-rollback-rate", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal 1, payload["projects"].size
      proj = payload["projects"].first
      assert_equal project, proj["project"]
      assert_equal 2, proj["total_fix_commits"]
      assert_equal 0, proj["reverted_commits"]
      assert proj["by_bias"].key?("courageous")
      assert proj["by_bias"].key?("safetyist")
    end
  end

  def test_rollback_rate_unknown_project_exits_2
    with_registered_project do |_dir, _project|
      _out, err, status = with_captured_exit do
        Hive::Commands::Metrics.new("rollback-rate", project: "no-such-project").call
      end
      assert_equal 2, status
      assert_match(/unknown project: no-such-project/, err)
    end
  end

  def test_unknown_subcommand_exits_2
    with_registered_project do |_dir, _project|
      _out, err, status = with_captured_exit do
        Hive::Commands::Metrics.new("totally-bogus").call
      end
      assert_equal 2, status
      assert_match(/unknown subcommand/, err)
    end
  end

  def test_no_registered_projects_exits_2
    with_tmp_global_config do
      _out, err, status = with_captured_exit do
        Hive::Commands::Metrics.new("rollback-rate").call
      end
      assert_equal 2, status
      assert_match(/no projects registered/, err)
    end
  end
end
