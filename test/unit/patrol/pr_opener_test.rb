require "test_helper"
require "yaml"
require "hive/config"
require "hive/markers"
require "hive/patrol/pr_opener"
require "hive/patrol/finding"
require "hive/task"

class HivePatrolPrOpenerTest < Minitest::Test
  include HiveTestHelper

  FakePatch = Struct.new(:finding, :branch, :worktree_path, :validation,
                         :passed, :diffstat, :head_sha, keyword_init: true)

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

  class FailingReviewHandoff
    def enqueue(**)
      raise "disk full"
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
      diffstat: " app.rb | 1 +",
      head_sha: "abc123"
    )
  end

  def test_validated_patch_opens_draft_pr_records_mapping_and_enqueues_review_task
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

      refute_nil result.review_task_path
      task = Hive::Task.new(result.review_task_path)
      assert_equal "review", task.stage_name
      assert_equal "patrol-feature-fp1", task.slug
      assert_equal "Patrol: Fix bug", task.display_name
      assert_equal :none, Hive::Markers.current(task.state_file).name
      assert File.directory?(task.reviews_dir)

      pointer = YAML.safe_load(File.read(task.worktree_yml_path))
      assert_equal dir, pointer.fetch("path")
      assert_equal "hive-patrol/feature-fp1", pointer.fetch("branch")
      assert_equal "abc123", pointer.fetch("execute_base_head")

      pr_md = File.read(File.join(task.folder, "pr.md"))
      assert_includes pr_md, "pr_url: https://example.com/pr/2"
      assert_includes File.read(task.state_file), "# Patrol: Fix bug"
    end
  end

  def test_review_handoff_failure_is_visible_and_retryable
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new

      result = Hive::Patrol::PrOpener.new(
        dir,
        cfg: cfg,
        gh: gh,
        review_handoff: FailingReviewHandoff.new
      ).open(finding, patch(worktree_path: dir))

      assert_equal :opened_review_handoff_failed, result.status
      assert result.opened?
      assert result.review_handoff_failed?
      assert_equal "review_handoff_failed", result.reason
      assert_nil result.review_task_path

      fingerprints = JSON.parse(File.read(File.join(dir, ".hive-state", "patrol", "fingerprints.json")))
      assert_equal "review_handoff_failed", fingerprints.fetch("fp1").fetch("state")
      refute Hive::Patrol::Fingerprint.known_active?(fingerprints, "fp1"),
             "failed review handoff must remain retryable instead of becoming an active PR skip"
    end
  end

  def test_review_handoff_frontmatter_handles_yaml_sensitive_values
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      unsafe = finding
      unsafe.id = "finding: one\nsecond"
      unsafe.fingerprint = "fp: one\nsecond"

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(unsafe, patch(worktree_path: dir))

      assert result.opened?
      task = Hive::Task.new(result.review_task_path)
      task_frontmatter = YAML.safe_load(File.read(task.state_file).match(/\A---\s*\n(.*?)\n---/m)[1])
      pr_frontmatter = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))

      assert_equal unsafe.id, task_frontmatter.fetch("patrol_finding_id")
      assert_equal unsafe.fingerprint, task_frontmatter.fetch("patrol_fingerprint")
      assert_equal "https://example.com/pr/2", pr_frontmatter.fetch("pr_url")
      assert_equal unsafe.id, pr_frontmatter.fetch("patrol_finding_id")
      assert_equal unsafe.fingerprint, pr_frontmatter.fetch("patrol_fingerprint")
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
      refute_nil result.review_task_path
      assert_empty gh.pushed
    end
  end

  def test_existing_merged_pr_does_not_enqueue_review_task
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      gh.prs = [ { "state" => "MERGED", "url" => "https://example.com/pr/1" } ]

      result = Hive::Patrol::PrOpener.new(dir, cfg: cfg, gh: gh).open(finding, patch(worktree_path: dir))

      assert_equal :skipped, result.status
      assert_equal "existing_pr", result.reason
      assert_nil result.review_task_path
      assert_empty gh.pushed
    end
  end

  def test_review_handoff_can_be_disabled
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state"))
      gh = FakeGh.new
      config = cfg(draft: false)
      config["patrol"]["review_prs"] = false

      result = Hive::Patrol::PrOpener.new(dir, cfg: config, gh: gh).open(finding, patch(worktree_path: dir))

      assert result.opened?
      assert_nil result.review_task_path
      refute Dir.exist?(File.join(dir, ".hive-state", "stages", "6-review"))
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
