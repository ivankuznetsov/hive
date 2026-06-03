require "test_helper"
require "hive/config"
require "hive/patrol/pr_opener"
require "hive/patrol/finding"

class HivePatrolPrOpenerTest < Minitest::Test
  include HiveTestHelper

  FakePatch = Struct.new(:finding, :branch, :worktree_path, :validation,
                         :passed, :diffstat, keyword_init: true)

  class FakeGh
    attr_reader :pushed, :created_args
    attr_accessor :prs, :diff

    def initialize
      @prs = []
      @diff = "diff --git a/app.rb b/app.rb\n+puts 'ok'\n"
      @pushed = []
      @created_args = nil
    end

    def lookup_prs_for_branch(_path, _branch, cfg: nil)
      @prs
    end

    def ensure_authenticated!(_cfg = nil)
      true
    end

    def push_branch!(path, branch, cfg: nil)
      @pushed << [ path, branch ]
    end

    def capture3(*cmd, chdir: nil, cfg: nil)
      if cmd[0] == "git"
        return [ @diff, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
      end

      @created_args = cmd
      [ "https://example.com/pr/2\n", "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
    end
  end

  def cfg(draft: true)
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      { "default_branch" => "master", "patrol" => { "draft_prs" => draft } }
    )
  end

  def finding
    Hive::Patrol::Finding.new(
      id: "f1",
      feature_id: "feature",
      category: "bug",
      severity: "high",
      confidence: "medium",
      title: "Fix bug",
      description: "bug details",
      recommendation: "fix it",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      fingerprint: "fp1"
    )
  end

  def patch(worktree_path: Dir.pwd, passed: true)
    FakePatch.new(
      finding: finding,
      branch: "hive-patrol/feature-fp1",
      worktree_path: worktree_path,
      passed: passed,
      validation: { "commands" => [ { "name" => "test", "command" => "rake", "exit_code" => 0 } ] },
      diffstat: " app.rb | 1 +"
    )
  end

  def test_validated_patch_opens_draft_pr_and_records_mapping
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert result.opened?
      assert_equal [ [ dir, "hive-patrol/feature-fp1" ] ], gh.pushed
      assert_includes gh.created_args, "--draft"
      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "https://example.com/pr/2", fingerprints["fp1"]["pr_url"]
      assert_equal "open", fingerprints["fp1"]["state"]
    end
  end

  def test_existing_open_pr_skips_duplicate
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ { "state" => "OPEN", "url" => "https://example.com/pr/1" } ]

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "existing_pr", result.reason
      assert_empty gh.pushed
    end
  end

  def test_secret_in_diff_blocks_pr
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.diff = "+api_key=#{'a' * 24}\n"

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :blocked, result.status
      assert_equal "secret_detected", result.reason
      assert_empty gh.pushed
    end
  end

  def test_diff_is_scanned_against_the_branch_base_not_just_last_commit
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      captured = nil
      gh.define_singleton_method(:capture3) do |*cmd, chdir: nil, cfg: nil|
        captured = cmd if cmd[0] == "git"
        [ @diff, "", Hive::Gh::CommandStatus.new(exitstatus: 0) ]
      end

      Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_includes captured, "master...HEAD",
                      "secret scan must diff the whole branch against its base, not HEAD~1..HEAD"
    end
  end

  def test_gh_error_during_pr_stage_cleans_up_and_returns_structured_error
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.define_singleton_method(:push_branch!) do |_path, _branch, cfg: nil|
        raise Hive::GhError, "push rejected"
      end

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :error, result.status
      assert_match(/gh_error/, result.reason)
      refute result.opened?
    end
  end

  def test_diff_for_gh_error_returns_empty_string
    with_tmp_dir do |dir|
      gh = FakeGh.new
      gh.define_singleton_method(:capture3) do |*|
        raise Hive::GhError, "git diff failed"
      end

      opener = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh)
      assert_equal "", opener.send(:diff_for, dir)
    end
  end
end
