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

  def test_idea_md_renders_cosmetic_evidence_branches
    # Cover the location-empty (`- evidence`), snippet-empty (bare
    # backticked location), and file-only `compact.join` variants of
    # evidence_text in one fixture.
    sparse_finding = Hive::Patrol::Finding.new(
      id: "f2", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Sparse", description: "details",
      recommendation: "fix it",
      evidence: [
        { "snippet" => "" },
        { "file" => "app.rb", "line" => 2, "snippet" => "" },
        { "file" => "only.rb", "snippet" => "context" }
      ],
      fingerprint: "fp2"
    )

    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: sparse_finding, patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )
      idea = File.read(File.join(folder, "idea.md"))

      assert_includes idea, "- evidence", "no file/line renders the bare evidence marker"
      assert_includes idea, "- `app.rb:2`", "empty snippet renders just the location"
      assert_includes idea, "- `only.rb`: context", "file-only location joins without a colon-line"
    end
  end

  def test_idea_md_omits_empty_finding_and_recommendation_sections
    # Whitespace-only description/recommendation must be treated as absent
    # so the body never emits a bare `## Finding` / `## Recommendation`
    # heading with no content under it.
    blank_finding = Hive::Patrol::Finding.new(
      id: "f4", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Blank sections", description: "   ",
      recommendation: nil,
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      fingerprint: "fp4"
    )

    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: blank_finding, patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )
      idea = File.read(File.join(folder, "idea.md"))

      refute_includes idea, "## Finding", "whitespace description omits the Finding heading"
      refute_includes idea, "## Recommendation", "nil recommendation omits the Recommendation heading"
      assert_includes idea, "## Evidence", "present evidence is still rendered"
    end
  end

  def test_display_name_falls_back_to_id_when_title_nil
    # A nil-title finding feeds both the `# ` heading and the
    # `original_text` provenance scalar; both must fall back to the id.
    untitled_finding = Hive::Patrol::Finding.new(
      id: "f5", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: nil, description: "details",
      recommendation: "fix it", evidence: nil, fingerprint: "fp5"
    )

    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: untitled_finding, patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )
      idea = File.read(File.join(folder, "idea.md"))
      frontmatter = YAML.safe_load(idea.split("---\n\n", 2).first)

      assert_includes idea, "# Patrol: f5", "nil title falls back to the finding id in the heading"
      assert_includes frontmatter.fetch("original_text"), "Patrol: f5",
                      "original_text provenance also carries the id fallback"
    end
  end

  def test_idea_md_tolerates_nil_evidence
    nil_evidence_finding = Hive::Patrol::Finding.new(
      id: "f3", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "No evidence", description: "details",
      recommendation: "fix it", evidence: nil, fingerprint: "fp3"
    )

    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: nil_evidence_finding, patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )
      idea = File.read(File.join(folder, "idea.md"))

      refute_includes idea, "## Evidence", "nil evidence omits the section instead of raising"
    end
  end
end
