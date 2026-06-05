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

  def test_slug_collides_within_6_review_and_gets_numeric_suffix
    with_tmp_dir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "6-review", "patrol-feature-fp1"))

      folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7")

      assert_equal "patrol-feature-fp1-2", File.basename(folder),
                   "a slug already taken in 6-review must get a numeric suffix"
    end
  end

  def test_slug_is_unique_across_all_stages_not_just_6_review
    with_tmp_dir do |dir|
      # A synthetic task that already advanced past 6-review must still reserve
      # its slug, or the slug-derived worktree/log-dir paths would collide.
      FileUtils.mkdir_p(File.join(dir, ".hive-state", "stages", "9-done", "patrol-feature-fp1"))

      folder = handoff(dir).enqueue(finding: finding, patch: patch(dir), pr_url: "https://example.com/pull/7")

      assert_equal "patrol-feature-fp1-2", File.basename(folder),
                   "slug uniqueness must scan every stage dir, not only 6-review"
    end
  end

  # Real patrol findings often omit recommendation/evidence and sometimes
  # the title. `idea_text` must drop the empty sections (not emit empty
  # `## Recommendation` / `## Evidence` headers), fall back to the finding
  # id when the title is nil, and tolerate a nil `evidence` array (a direct
  # `Finding.new`, unlike `from_h`, does not coerce it) without raising.
  def sparse_finding
    Hive::Patrol::Finding.new(
      id: "f9", feature_id: "feature", category: "bug", severity: "low",
      confidence: "low", title: nil, description: "only a description",
      recommendation: "", evidence: nil, fingerprint: "fp9"
    )
  end

  def test_enqueue_idea_md_drops_empty_sections_and_falls_back_to_id
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: sparse_finding,
        patch: patch(dir),
        pr_url: "https://example.com/pull/7",
        now: Time.utc(2026, 6, 5, 12, 0, 0)
      )

      idea = File.read(File.join(folder, "idea.md"))

      assert_includes idea, "Patrol: f9",
                      "a nil title must fall back to the finding id"
      assert_includes idea, "## Finding"
      assert_includes idea, "only a description"
      refute_includes idea, "## Recommendation",
                      "an empty recommendation must not emit a header"
      refute_includes idea, "## Evidence",
                      "a nil/empty evidence array must not emit a header"
    end
  end

  def test_enqueue_idea_md_renders_location_only_evidence_fallback
    with_tmp_dir do |dir|
      located = Hive::Patrol::Finding.new(
        id: "f10", feature_id: "feature", category: "bug", severity: "low",
        confidence: "low", title: "Located", description: "d",
        recommendation: "", fingerprint: "fp10",
        evidence: [ { "snippet" => "" }, { "file" => "x.rb", "line" => 2, "snippet" => "" } ]
      )

      folder = handoff(dir).enqueue(
        finding: located, patch: patch(dir),
        pr_url: "https://example.com/pull/7", now: Time.utc(2026, 6, 5, 12, 0, 0)
      )

      idea = File.read(File.join(folder, "idea.md"))

      assert_includes idea, "- evidence",
                      "an evidence entry with no file/line falls back to a bare `- evidence` line"
      assert_includes idea, "- `x.rb:2`",
                      "an evidence entry with file/line but no snippet renders location-only"
    end
  end

  def test_enqueue_writes_idea_md_from_original_finding
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding,
        patch: patch(dir),
        pr_url: "https://example.com/pull/7",
        now: Time.utc(2026, 6, 5, 12, 0, 0)
      )

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
end
