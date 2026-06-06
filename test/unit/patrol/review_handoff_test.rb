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

  # The evidence comes from unvalidated LLM JSON; the non-Hash / malformed-Hash
  # guard in evidence_text is load-bearing. These exercise the exact shapes it
  # exists to survive so a regression assuming `entry["file"]` fails loudly.
  def idea_md_for(evidence)
    with_tmp_dir do |dir|
      crafted = Hive::Patrol::Finding.new(
        id: "fe", feature_id: "feature", category: "bug", severity: "high",
        confidence: "medium", title: "Evidence shapes", description: "details",
        recommendation: "fix", evidence: evidence, fingerprint: "fpe"
      )
      folder = handoff(dir).enqueue(
        finding: crafted, patch: patch(dir),
        pr_url: "https://example.com/pull/11", now: Time.utc(2026, 6, 5, 12, 0, 0)
      )
      yield File.read(File.join(folder, "idea.md"))
    end
  end

  def test_evidence_text_renders_a_bare_string_entry
    idea_md_for([ "see the retry loop", "  " ]) do |idea|
      assert_includes idea, "## Evidence"
      assert_includes idea, "- see the retry loop", "a String entry must render as a plain bullet"
      assert_includes idea, "- evidence", "a blank String entry must fall back to a placeholder bullet"
    end
  end

  def test_evidence_text_handles_a_hash_missing_file_and_line
    idea_md_for([ { "snippet" => "x = 1" } ]) do |idea|
      assert_includes idea, "- evidence: x = 1",
                      "a Hash with no file/line must not raise and must keep the snippet"
    end
  end

  def test_evidence_text_omits_a_blank_snippet
    idea_md_for([ { "file" => "app.rb", "line" => 3, "snippet" => "  " } ]) do |idea|
      assert_includes idea, "- `app.rb:3`"
      refute_includes idea, "`app.rb:3`: ", "a blank snippet must not append a trailing separator"
    end
  end

  def test_evidence_text_normalizes_a_single_hash_shaped_evidence_object
    # An unwrapped LLM `"evidence": {…}` object must render as one location
    # bullet, not Array()'s mangled `- ["file", "x.rb"]` decomposition.
    idea_md_for({ "file" => "x.rb", "line" => 5, "snippet" => "boom" }) do |idea|
      assert_includes idea, "- `x.rb:5`: boom",
                      "a top-level Hash evidence object must be wrapped into one entry"
      refute_includes idea, "[\"file\"", "evidence must not be decomposed into [k, v] pairs"
    end
  end
end
