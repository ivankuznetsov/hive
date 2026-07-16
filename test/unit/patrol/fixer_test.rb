require "test_helper"
require "hive/config"
require "hive/patrol/fixer"
require "hive/patrol/finding"
require "hive/usage_db"

class HivePatrolFixerTest < Minitest::Test
  include HiveTestHelper

  def cfg(repo)
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      {
        "default_branch" => "master",
        "worktree_root" => File.join(File.dirname(repo), "worktrees"),
        "patrol" => {
          "commands" => { "test" => "ruby -c app.rb" }
        }
      }
    )
  end

  def finding
    Hive::Patrol::Finding.new(
      id: "route-users-1",
      feature_id: "route-users",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Syntax fix",
      description: "app has a bug",
      recommendation: "write valid ruby",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      fingerprint: "abcdef1234567890"
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

  def test_successful_fix_is_committed_and_patch_recorded
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      base_sha = run!("git", "-C", repo, "rev-parse", "HEAD").strip
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      assert_equal true, patch.passed
      assert_equal base_sha, patch.base_sha
      refute_equal patch.base_sha, patch.head_sha
      assert_match(/app\.rb/, patch.diffstat)
      assert File.directory?(patch.worktree_path), "passed fix worktree remains for PR creation"
      assert File.exist?(Dir[File.join(repo, ".hive-state", "patrol", "patches", "*.json")].first)
      record = JSON.parse(File.read(Dir[File.join(repo, ".hive-state", "patrol", "patches", "*.json")].first))
      assert_equal base_sha, record.fetch("base_sha")
      assert_equal "puts 'old'\n", File.read(File.join(repo, "app.rb")),
                   "managed repo worktree must stay untouched"
    end
  end

  def test_validation_failure_removes_worktree_and_opens_no_pr_path
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      bad_cfg = cfg(repo)
      bad_cfg["patrol"]["commands"]["test"] = "ruby -c app.rb"
      agent = ->(worktree_path:, **) { File.write(File.join(worktree_path, "app.rb"), "if\n") }

      patch = Hive::Patrol::Fixer.new(repo, cfg: bad_cfg, agent_runner: agent).attempt(finding)

      assert_equal false, patch.passed
      refute File.directory?(patch.worktree_path), "failed fix worktree should be removed"
    end
  end

  def test_failed_fix_agent_run_is_not_validated_or_shipped
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")
      # Agent#run! reports a non-zero exit via status :error rather than
      # raising, yet still leaves a (would-be valid) change behind.
      agent = lambda do |worktree_path:, **|
        File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n")
        { status: :error, error_message: "exit_code=1" }
      end

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      assert_equal false, patch.passed, "a failed fix agent must never produce a validated patch"
      assert_equal "fix_agent_failed", patch.validation["reason"]
      refute_nil patch.base_sha, "a created worktree must retain its captured base on agent failure"
      refute File.directory?(patch.worktree_path), "failed-agent worktree should be removed"
    end
  end

  def test_missing_validation_commands_fails_closed
    with_tmp_git_repo do |repo|
      empty_cfg = cfg(repo)
      empty_cfg["patrol"]["commands"] = {}
      agent = ->(worktree_path:, **) { File.write(File.join(worktree_path, "README.md"), "changed\n") }

      patch = Hive::Patrol::Fixer.new(repo, cfg: empty_cfg, agent_runner: agent).attempt(finding)

      assert_equal false, patch.passed
      assert_equal "no_validation_commands", patch.validation["reason"]
    end
  end

  def test_attempt_records_failed_patch_when_worktree_creation_raises
    with_tmp_git_repo do |repo|
      worktree = Object.new
      def worktree.path = "/tmp/hive-missing-worktree"
      def worktree.create!(*)
        raise Hive::GitError, "create failed"
      end
      def worktree.remove!(**)
        raise Hive::GitError, "remove failed"
      end

      patch = Hive::Patrol::Fixer.new(
        repo,
        cfg: cfg(repo),
        worktree_factory: ->(**) { worktree }
      ).attempt(finding)

      assert_equal false, patch.passed
      assert_equal "fix_error", patch.validation["reason"]
      assert_nil patch.base_sha
    end
  end

  def test_agent_failed_cleanup_swallows_remove_failure
    with_tmp_git_repo do |repo|
      worktree = Object.new
      worktree.instance_variable_set(:@path, repo)
      def worktree.path = @path
      def worktree.create!(*); end
      def worktree.remove!(**)
        raise Hive::GitError, "remove failed"
      end

      patch = Hive::Patrol::Fixer.new(
        repo,
        cfg: cfg(repo),
        worktree_factory: ->(**) { worktree },
        agent_runner: ->(**) { { status: :error, error_message: "bad" } }
      ).attempt(finding)

      assert_equal false, patch.passed
      assert_equal "fix_agent_failed", patch.validation["reason"]
      assert_equal run!("git", "-C", repo, "rev-parse", "HEAD").strip, patch.base_sha
    end
  end

  def test_run_agent_wrapper_constructs_agent
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      fake_agent = Object.new
      def fake_agent.run! = { status: :ok }

      profiles_singleton = class << Hive::AgentProfiles; self; end
      agent_singleton = class << Hive::Agent; self; end
      profiles_lookup = Hive::AgentProfiles.method(:lookup)
      agent_new = Hive::Agent.method(:new)
      profiles_singleton.define_method(:lookup) { |*| :profile }
      agent_singleton.define_method(:new) { |*| fake_agent }
      assert_equal({ status: :ok },
                   fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo))
    ensure
      profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_lookup
      agent_singleton.define_method(:new, agent_new) if agent_new
    end
  end

  def test_run_agent_wrapper_records_patrol_fix_usage
    with_tmp_git_repo do |repo|
      with_usage_db do
        fixer_cfg = cfg(repo)
        fixer_cfg["patrol"]["agent"] = "codex"
        fixer = Hive::Patrol::Fixer.new(repo, cfg: fixer_cfg)
        fake_agent = Object.new
        def fake_agent.run!
          {
            status: :ok,
            model: "fallback-model",
            usage: { input: 80, output: 20, cached: 10 }
          }
        end

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        profile = Struct.new(:name).new("codex")
        profiles_singleton.define_method(:lookup) { |*| profile }
        agent_singleton.define_method(:new) { |*| fake_agent }

        fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo)

        rows = usage_rows
        assert_equal 1, rows.size
        row = rows.first
        assert_equal "codex", row["agent"]
        assert_equal "fallback-model", row["model"]
        assert_equal File.basename(repo), row["project_slug"]
        assert_equal "patrol-fix", row["task_slug"]
        assert_equal "patrol-fix", row["stage"]
        assert_equal 80, row["input"]
        assert_equal 20, row["output"]
        assert_equal 10, row["cached"]
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end

  def test_run_agent_wrapper_does_not_raise_when_usage_recording_fails
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      fake_agent = Object.new
      def fake_agent.run!
        { status: :ok, usage: { input: 1, output: 2, cached: 3 } }
      end

      profiles_singleton = class << Hive::AgentProfiles; self; end
      agent_singleton = class << Hive::Agent; self; end
      usage_singleton = class << Hive::UsageDb; self; end
      profiles_lookup = Hive::AgentProfiles.method(:lookup)
      agent_new = Hive::Agent.method(:new)
      usage_record = Hive::UsageDb.method(:record!)
      profiles_singleton.define_method(:lookup) { |*| Struct.new(:name).new("claude") }
      agent_singleton.define_method(:new) { |*| fake_agent }
      usage_singleton.define_method(:record!) { |**| raise "db locked" }

      result = nil
      _out, err = capture_io do
        result = fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo)
      end

      assert_equal({ status: :ok, usage: { input: 1, output: 2, cached: 3 } }, result)
      assert_match(/usage record failed: db locked/, err)
    ensure
      profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
      agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      usage_singleton.define_method(:record!, usage_record) if usage_singleton && usage_record
    end
  end

  def test_run_agent_wrapper_falls_back_to_config_agent_for_nameless_profile
    with_tmp_git_repo do |repo|
      with_usage_db do
        fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
        fake_agent = Object.new
        def fake_agent.run!
          { status: :ok, usage: { input: 1, output: 2, cached: 3 } }
        end

        profiles_singleton = class << Hive::AgentProfiles; self; end
        agent_singleton = class << Hive::Agent; self; end
        profiles_lookup = Hive::AgentProfiles.method(:lookup)
        agent_new = Hive::Agent.method(:new)
        # A profile object WITHOUT #name exercises profile_name's config fallback.
        profiles_singleton.define_method(:lookup) { |*| Object.new }
        agent_singleton.define_method(:new) { |*| fake_agent }

        fixer.send(:run_agent, prompt: "p", run_dir: repo, worktree_path: repo)

        rows = usage_rows
        assert_equal 1, rows.size
        assert_equal "claude", rows.first["agent"],
                     "a profile without #name must fall back to the configured patrol agent (default claude)"
      ensure
        profiles_singleton.define_method(:lookup, profiles_lookup) if profiles_singleton && profiles_lookup
        agent_singleton.define_method(:new, agent_new) if agent_singleton && agent_new
      end
    end
  end

  def test_committed_since_base_detects_branch_delta
    with_tmp_git_repo do |repo|
      fixer = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo))
      base_sha = run!("git", "-C", repo, "rev-parse", "HEAD").strip

      assert_equal false, fixer.send(:committed_since_base?, repo, base_sha)

      run!("git", "-C", repo, "checkout", "-b", "feature", "--quiet")
      File.write(File.join(repo, "feature.txt"), "changed\n")
      run!("git", "-C", repo, "add", "feature.txt")
      run!("git", "-C", repo, "commit", "-m", "feature", "--quiet")

      assert_equal true, fixer.send(:committed_since_base?, repo, base_sha)
    end
  end

  def test_patch_diffstat_uses_actual_worktree_base_when_local_default_is_stale
    with_stale_local_default do |repo, upstream_sha|
      agent = ->(worktree_path:, **) { File.write(File.join(worktree_path, "app.rb"), "puts 'fixed'\n") }

      patch = Hive::Patrol::Fixer.new(repo, cfg: cfg(repo), agent_runner: agent).attempt(finding)

      assert_equal true, patch.passed
      assert_equal upstream_sha, patch.base_sha
      assert_match(/app\.rb/, patch.diffstat)
      refute_match(/upstream\.txt/, patch.diffstat)
    end
  end

  def test_no_change_does_not_pass_only_because_local_default_is_stale
    with_stale_local_default do |repo, upstream_sha|
      patch = Hive::Patrol::Fixer.new(
        repo,
        cfg: cfg(repo),
        agent_runner: ->(**) { { status: :ok } }
      ).attempt(finding)

      assert_equal upstream_sha, patch.base_sha
      assert_equal false, patch.passed
    end
  end

  private

  def with_stale_local_default
    with_tmp_git_repo do |repo|
      File.write(File.join(repo, "app.rb"), "puts 'old'\n")
      run!("git", "-C", repo, "add", ".")
      run!("git", "-C", repo, "commit", "-m", "app", "--quiet")

      with_tmp_dir do |remote|
        run!("git", "-C", remote, "init", "--bare", "--quiet")
        run!("git", "-C", repo, "remote", "add", "origin", remote)
        run!("git", "-C", repo, "push", "-u", "origin", "master", "--quiet")

        with_tmp_dir do |upstream|
          run!("git", "clone", "--quiet", remote, upstream)
          run!("git", "-C", upstream, "config", "user.email", "test@example.com")
          run!("git", "-C", upstream, "config", "user.name", "Test")
          run!("git", "-C", upstream, "config", "commit.gpgsign", "false")
          File.write(File.join(upstream, "upstream.txt"), "new upstream file\n")
          run!("git", "-C", upstream, "add", "upstream.txt")
          run!("git", "-C", upstream, "commit", "-m", "upstream", "--quiet")
          upstream_sha = run!("git", "-C", upstream, "rev-parse", "HEAD").strip
          run!("git", "-C", upstream, "push", "origin", "master", "--quiet")

          yield repo, upstream_sha
        end
      end
    end
  end
end
