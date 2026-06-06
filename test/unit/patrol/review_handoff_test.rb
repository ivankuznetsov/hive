require "test_helper"
require "yaml"
require "hive/config"
require "hive/patrol/finding"
require "hive/patrol/review_handoff"

class HivePatrolReviewHandoffTest < Minitest::Test
  include HiveTestHelper

  Patch = Struct.new(:branch, :worktree_path, :head_sha, keyword_init: true)

  def finding
    Hive::Patrol::Finding.new(
      id: "f1", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Fix bug", description: "bug details",
      recommendation: "fix it",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      fingerprint: "fp1"
    )
  end

  def patch(dir)
    Patch.new(branch: "hive-patrol/feature-fp1", worktree_path: dir, head_sha: "abc123")
  end

  def handoff(dir)
    Hive::Patrol::ReviewHandoff.new(dir, cfg: Hive::Config.deep_dup(Hive::Config::DEFAULTS), state: {})
  end

  def with_task_counter(value = 42)
    with_replaced_singleton_method(Hive::TaskCounter, :next!, lambda { value }) do
      yield
    end
  end

  def test_slug_collides_within_6_review_and_gets_numeric_suffix
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "6-review", "patrol-feature-fp1"))

      folder = nil
      with_task_counter { folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7") }

      assert_equal "patrol-feature-fp1-2", File.basename(folder),
                   "a slug already taken in 6-review must get a numeric suffix"
    end
  end

  def test_slug_is_unique_across_all_stages_not_just_6_review
    with_tmp_dir do |dir|
      # A synthetic task that already advanced past 6-review must still reserve
      # its slug, or the slug-derived worktree/log-dir paths would collide.
      FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "9-done", "patrol-feature-fp1"))

      folder = nil
      with_task_counter { folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7") }

      assert_equal "patrol-feature-fp1-2", File.basename(folder),
                   "slug uniqueness must scan every stage dir, not only 6-review"
    end
  end

  def test_enqueue_writes_idea_md_from_original_finding
    with_tmp_dir do |dir|
      folder = nil
      with_task_counter do
        folder = handoff(dir).enqueue(
          finding: finding,
          patch: patch(dir),
          pr_url: "https://example.com/pull/7",
          now: Time.utc(2026, 6, 5, 12, 0, 0)
        )
      end

      idea = File.read(File.join(folder, "idea.md"))
      frontmatter = YAML.safe_load(idea.split("---\n\n", 2).first)

      assert_equal "patrol", frontmatter.fetch("source")
      assert_equal "f1", frontmatter.fetch("patrol_finding_id")
      assert_equal "fp1", frontmatter.fetch("patrol_fingerprint")
      assert_includes frontmatter.fetch("original_text"), "Patrol: Fix bug"
      assert_includes idea, "## Finding"
      assert_includes idea, "bug details"
      assert_includes idea, "## Recommendation"
      assert_includes idea, "fix it"
      assert_includes idea, "`app.rb:1`: puts"
    end
  end

  def test_enqueue_writes_task_id_and_falls_back_to_null_when_counter_is_busy
    with_tmp_dir do |dir|
      folder = nil
      with_task_counter(123) do
        folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7")
      end

      assert_equal 123, Hive::TaskMeta.read(folder)[:id]
    end

    with_tmp_dir do |dir|
      with_replaced_singleton_method(Hive::TaskCounter, :next!, lambda { raise Hive::ConcurrentRunError, "busy" }) do
        folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7")

        assert_nil Hive::TaskMeta.read(folder)[:id]
      end
    end
  end
end
