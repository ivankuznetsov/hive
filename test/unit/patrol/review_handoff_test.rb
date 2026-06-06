require "test_helper"
require "yaml"
require "hive/config"
require "hive/patrol/finding"
require "hive/patrol/review_handoff"

class HivePatrolReviewHandoffTest < Minitest::Test
  include HiveTestHelper

  Patch = Struct.new(:branch, :worktree_path, :head_sha, keyword_init: true)

  def finding(**overrides)
    defaults = {
      id: "f1", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Fix bug", description: "bug details",
      recommendation: "fix it",
      evidence: [ { "file" => "app.rb", "line" => 1, "snippet" => "puts" } ],
      fingerprint: "fp1"
    }
    Hive::Patrol::Finding.new(**defaults.merge(overrides))
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

  # Read the idea.md body — the segment after the frontmatter — so body
  # assertions cannot be satisfied by the same text echoed into the
  # `original_text` frontmatter mirror.
  def idea_body(folder)
    File.read(File.join(folder, "idea.md")).split("---\n\n", 2).last
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

      body = idea_body(folder)
      assert_includes body, "## Finding", "the body must render the finding section, not just the frontmatter mirror"
      assert_includes body, "bug details"
      assert_includes body, "## Recommendation"
      assert_includes body, "fix it"
      assert_includes body, "`app.rb:1`: puts"
    end
  end

  def test_idea_md_skips_empty_sections
    bare = Hive::Patrol::Finding.new(
      id: "f3", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Bare finding", description: "",
      recommendation: "   ", evidence: [], fingerprint: "fp3"
    )
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(finding: bare, patch: patch(dir), pr_url: "https://example.com/pull/7")
      body = idea_body(folder)

      assert_includes body, "# Patrol: Bare finding"
      refute_includes body, "## Finding", "blank description must not emit a Finding section"
      refute_includes body, "## Recommendation", "whitespace-only recommendation must not emit a section"
      refute_includes body, "## Evidence", "empty evidence must not emit an Evidence section"
    end
  end

  def test_idea_md_renders_each_evidence_branch
    ev = Hive::Patrol::Finding.new(
      id: "f4", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "Evidence finding", description: "d",
      recommendation: "r",
      evidence: [
        { "snippet" => "loose snippet" },                   # no location, has snippet
        {},                                                 # no location, no snippet
        { "file" => "a.rb", "line" => 9, "snippet" => "" }  # location, blank snippet
      ],
      fingerprint: "fp4"
    )
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(finding: ev, patch: patch(dir), pr_url: "https://example.com/pull/7")
      body = idea_body(folder)

      assert_includes body, "## Evidence"
      assert_includes body, "- evidence: loose snippet", "no-location entry with a snippet renders the snippet"
      assert_includes body, "\n- evidence\n", "no-location entry without a snippet renders a bare marker"
      assert_includes body, "- `a.rb:9`", "located entry with a blank snippet renders just the location"
      refute_includes body, "`a.rb:9`:", "a blank snippet must not leave a trailing colon"
    end
  end

  def test_idea_md_survives_finding_built_without_evidence
    # A Finding constructed outside from_h can carry nil evidence; idea_text
    # must guard with Array(...) rather than calling nil.empty?.
    no_ev = Hive::Patrol::Finding.new(
      id: "f5", feature_id: "feature", category: "bug", severity: "high",
      confidence: "medium", title: "No evidence", description: "d",
      recommendation: "r", evidence: nil, fingerprint: "fp5"
    )
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(finding: no_ev, patch: patch(dir), pr_url: "https://example.com/pull/7")
      body = idea_body(folder)

      assert_includes body, "# Patrol: No evidence"
      refute_includes body, "## Evidence", "nil evidence must be treated as empty, not raise"
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

  def test_idea_md_omits_finding_section_when_description_blank
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(description: "   "),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      refute_includes idea, "## Finding", "blank description must omit the Finding section"
      assert_includes idea, "## Recommendation", "other sections must still render"
    end
  end

  def test_idea_md_omits_recommendation_section_when_blank
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(recommendation: ""),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      refute_includes idea, "## Recommendation", "blank recommendation must omit the Recommendation section"
      assert_includes idea, "## Finding", "other sections must still render"
    end
  end

  def test_idea_md_omits_evidence_section_when_evidence_empty
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(evidence: []),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      refute_includes idea, "## Evidence", "empty evidence must omit the Evidence section"
    end
  end

  def test_idea_md_renders_evidence_without_location_as_bare_marker
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(evidence: [ { "snippet" => "boom" } ]),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      assert_includes idea, "- evidence: boom",
                      "evidence with no file/line must render the bare '- evidence' marker"
    end
  end

  def test_idea_md_renders_location_only_when_snippet_blank
    with_tmp_dir do |dir|
      folder = handoff(dir).enqueue(
        finding: finding(evidence: [ { "file" => "app.rb", "line" => 9, "snippet" => "  " } ]),
        patch: patch(dir),
        pr_url: "https://example.com/pull/7"
      )

      idea = File.read(File.join(folder, "idea.md"))
      assert_includes idea, "- `app.rb:9`", "a snippet-less entry must render location only"
      refute_match(/app\.rb:9`:/, idea, "no trailing snippet separator when snippet is blank")
    end
  end
end
