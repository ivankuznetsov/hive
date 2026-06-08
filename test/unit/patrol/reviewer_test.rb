require "test_helper"
require "json"
require "hive/config"
require "hive/patrol/reviewer"
require "hive/patrol/feature"
require "hive/usage_db"

class HivePatrolReviewerTest < Minitest::Test
  include HiveTestHelper

  def cfg
    Hive::Config.deep_dup(Hive::Config::DEFAULTS)
  end

  def feature
    Hive::Patrol::Feature.new(
      id: "route-users",
      kind: "route",
      entrypoints: [ "app.rb" ],
      owned_files: [ "app.rb" ],
      context_files: [],
      tests: []
    )
  end

  def with_usage_db
    old_path = Hive::UsageDb.path
    with_tmp_dir do |dir|
      Hive::UsageDb.path = File.join(dir, "usage.db")
      yield
    ensure
      Hive::UsageDb.path = old_path
    end
  end

  def usage_rows
    require "sqlite3"

    db = SQLite3::Database.new(Hive::UsageDb.path)
    db.results_as_hash = true
    db.execute("SELECT agent, model, project_slug, task_slug, stage, input, output, cached FROM token_usage")
  ensure
    db&.close
  end

  def test_persists_schema_valid_findings_from_agent_output
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      runner = lambda do |output_path:, **|
        File.write(output_path, JSON.generate(
          "findings" => [
            {
              "category" => "bug",
              "severity" => "high",
              "confidence" => "medium",
              "title" => "Crash",
              "description" => "nil crash",
              "recommendation" => "guard",
              "evidence" => [ { "file" => "app.rb", "line" => 1, "snippet" => "nil" } ]
            }
          ]
        ))
      end

      findings = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner).call([ feature ])

      assert_equal 1, findings.size
      assert_equal "route-users-1", findings.first.id
      assert File.exist?(File.join(dir, ".hive-state", "patrol", "findings", "route-users-1.json"))
    end
  end

  def test_malformed_agent_json_records_error_and_returns_no_findings
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      runner = ->(output_path:, **) { File.write(output_path, "not-json") }

      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)
      findings = reviewer.call([ feature ])

      assert_empty findings
      error_logs = Dir[File.join(dir, ".hive-state", "patrol", "runs", "review-error-*.json")]
      refute_empty error_logs
      assert_equal 1, reviewer.review_errors.size
      assert_equal "malformed_json", reviewer.review_errors.first["error"]
    end
  end

  def other_feature
    Hive::Patrol::Feature.new(
      id: "route-admin",
      kind: "route",
      entrypoints: [ "admin.rb" ],
      owned_files: [ "admin.rb" ],
      context_files: [],
      tests: []
    )
  end

  # One feature's agent failing (Agent#run! returns status :error and
  # writes no output) must not abort the whole scan. The other feature's
  # findings survive and the failure is recorded so the caller can refuse
  # to advance last_scanned_sha.
  def test_one_feature_agent_failure_is_non_fatal
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      runner = lambda do |feature:, output_path:, **|
        if feature.id == "route-users"
          { status: :error, error_message: "exit_code=1" }
        else
          File.write(output_path, JSON.generate(
            "findings" => [
              {
                "category" => "bug", "severity" => "high", "confidence" => "medium",
                "title" => "Crash", "description" => "nil crash",
                "recommendation" => "guard",
                "evidence" => [ { "file" => "admin.rb", "line" => 1, "snippet" => "nil" } ]
              }
            ]
          ))
        end
      end

      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg, agent_runner: runner)
      findings = reviewer.call([ feature, other_feature ])

      assert_equal 1, findings.size, "the healthy feature's findings must survive a sibling's agent failure"
      assert_equal "route-admin-1", findings.first.id
      assert_equal 1, reviewer.review_errors.size
      assert_equal "agent_failed", reviewer.review_errors.first["error"]
    end
  end

  def test_unexpected_review_error_is_recorded
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      reviewer = Hive::Patrol::Reviewer.new(
        dir,
        cfg: cfg,
        agent_runner: ->(**) { raise IOError, "boom" }
      )

      assert_empty reviewer.call([ feature ])
      assert_equal "review_error", reviewer.review_errors.first["error"]
    end
  end

  def test_run_agent_wrapper_constructs_agent
    with_tmp_dir do |dir|
      reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg)
      fake_agent = Object.new
      def fake_agent.run! = { status: :ok }

      profiles_singleton = class << Hive::AgentProfiles; self; end
      agent_singleton = class << Hive::Agent; self; end
      profiles_lookup = Hive::AgentProfiles.method(:lookup)
      agent_new = Hive::Agent.method(:new)
      profiles_singleton.define_method(:lookup) { |*| :profile }
      agent_singleton.define_method(:new) { |*| fake_agent }
      assert_equal({ status: :ok },
                   reviewer.send(:run_agent, prompt: "p",
                                             output_path: File.join(dir, "out.json"),
                                             run_dir: dir))
    ensure
      profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_lookup
      agent_singleton.define_method(:new, agent_new) if agent_new
    end
  end

  def test_run_agent_wrapper_records_patrol_review_usage
    with_tmp_dir do |dir|
      with_usage_db do
        cfg = self.cfg
        cfg["patrol"]["agent"] = "codex"
        reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg)
        fake_agent = Object.new
        def fake_agent.run!
          {
            status: :ok,
            model: "fallback-model",
            usage: { model: "usage-model", input: 123, output: 45, cached: 6 }
          }
        end

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        profile = Struct.new(:name).new("codex")
        profiles_singleton.define_method(:lookup) { |*| profile }
        agent_singleton.define_method(:new) { |*| fake_agent }

        reviewer.send(:run_agent, prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)

        rows = usage_rows
        assert_equal 1, rows.size
        row = rows.first
        assert_equal "codex", row["agent"]
        assert_equal "usage-model", row["model"]
        assert_equal File.basename(dir), row["project_slug"]
        assert_equal "patrol-review", row["task_slug"]
        assert_equal "patrol-review", row["stage"]
        assert_equal 123, row["input"]
        assert_equal 45, row["output"]
        assert_equal 6, row["cached"]
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end

  def test_run_agent_wrapper_without_usage_writes_no_usage_row
    with_tmp_dir do |dir|
      with_usage_db do
        reviewer = Hive::Patrol::Reviewer.new(dir, cfg: cfg)
        fake_agent = Object.new
        def fake_agent.run! = { status: :ok }

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        profiles_singleton.define_method(:lookup) { |*| Struct.new(:name).new("claude") }
        agent_singleton.define_method(:new) { |*| fake_agent }

        reviewer.send(:run_agent, prompt: "p", output_path: File.join(dir, "out.json"), run_dir: dir)

        refute File.exist?(Hive::UsageDb.path)
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end
end
