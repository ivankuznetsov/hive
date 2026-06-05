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
      # Parse the YAML block between the frontmatter delimiters rather than
      # splitting on the writer's exact `---\n\n` spacing, so a formatting
      # change to write_frontmatter_md can't break this on whitespace.
      frontmatter = YAML.safe_load(idea[/\A---\n(.*?)\n---/m, 1])

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

  def finding_with_evidence(evidence)
    Hive::Patrol::Finding.new(
      id: "f1", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Fix bug", description: "bug details",
      recommendation: "fix it", evidence: evidence, fingerprint: "fp1"
    )
  end

  def idea_md_for(evidence)
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding_with_evidence(evidence),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )
      return File.read(File.join(folder, "idea.md"))
    end
  end

  def test_evidence_section_omitted_when_evidence_is_nil
    # Finding is a plain Struct enforcing no evidence invariant; a finding
    # built without evidence: yields nil. enqueue must not raise and must
    # omit the Evidence heading entirely.
    idea = idea_md_for(nil)
    refute_includes idea, "## Evidence"
  end

  def test_evidence_section_omitted_when_evidence_is_empty
    idea = idea_md_for([])
    refute_includes idea, "## Evidence"
  end

  def test_evidence_entry_without_location_renders_bare_marker
    idea = idea_md_for([ { "snippet" => "orphan snippet" } ])
    assert_includes idea, "## Evidence"
    assert_includes idea, "- evidence: orphan snippet"
  end

  def test_evidence_entry_without_location_or_snippet_renders_marker_only
    idea = idea_md_for([ {} ])
    assert_includes idea, "## Evidence"
    assert_match(/^- evidence$/, idea)
  end

  def test_evidence_entry_with_location_but_empty_snippet_omits_colon_suffix
    idea = idea_md_for([ { "file" => "a.rb", "line" => 3, "snippet" => "" } ])
    assert_includes idea, "- `a.rb:3`"
    refute_includes idea, "`a.rb:3`:"
  end

  def test_evidence_entry_accepts_symbol_keys
    # Sibling code (fingerprint.rb, pr_opener.rb) tolerates symbol-keyed
    # evidence; a symbol-keyed entry must render the real location rather
    # than silently degrading to the bare "- evidence" marker.
    idea = idea_md_for([ { file: "sym.rb", line: 9, snippet: "code" } ])
    assert_includes idea, "- `sym.rb:9`: code"
    refute_includes idea, "- evidence"
  end
end
