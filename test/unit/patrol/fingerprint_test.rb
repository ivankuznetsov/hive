require "test_helper"
require "hive/patrol/fingerprint"
require "hive/patrol/finding"

class HivePatrolFingerprintTest < Minitest::Test
  include HiveTestHelper

  def finding(category: "bug", line: 1)
    Hive::Patrol::Finding.new(
      id: "f1",
      feature_id: "route-users",
      category: category,
      severity: "high",
      confidence: "medium",
      title: "Nil user crash",
      description: "The route crashes on nil user",
      recommendation: "Guard nil user",
      evidence: [ { "file" => "app.rb", "line" => line, "snippet" => "user.name" } ]
    )
  end

  def test_same_logical_finding_survives_line_shift
    with_tmp_dir do |dir|
      File.write(File.join(dir, "app.rb"), "user.name\n")
      first = Hive::Patrol::Fingerprint.compute(finding(line: 1), project_root: dir)
      File.write(File.join(dir, "app.rb"), "\n\nuser.name\n")
      second = Hive::Patrol::Fingerprint.compute(finding(line: 3), project_root: dir)

      assert_equal first, second
    end
  end

  def test_different_category_changes_fingerprint
    with_tmp_dir do |dir|
      File.write(File.join(dir, "app.rb"), "user.name\n")
      bug = Hive::Patrol::Fingerprint.compute(finding(category: "bug"), project_root: dir)
      security = Hive::Patrol::Fingerprint.compute(finding(category: "security"), project_root: dir)

      refute_equal bug, security
    end
  end

  def test_active_and_dismissed_state_helpers
    assert Hive::Patrol::Fingerprint.known_active?({ "abc" => { "state" => "open" } }, "abc")
    refute Hive::Patrol::Fingerprint.known_active?({ "abc" => { "state" => "dismissed" } }, "abc")
    assert Hive::Patrol::Fingerprint.dismissed?({ "abc" => {} }, "abc")
  end

  def test_safe_repo_path_rejects_traversal_and_absolute_paths
    with_tmp_dir do |dir|
      assert_nil Hive::Patrol::Fingerprint.safe_repo_path(dir, "../secrets.env")
      assert_nil Hive::Patrol::Fingerprint.safe_repo_path(dir, "../../etc/passwd")
      assert_nil Hive::Patrol::Fingerprint.safe_repo_path(dir, "/etc/passwd")
      assert_equal File.join(File.expand_path(dir), "app.rb"),
                   Hive::Patrol::Fingerprint.safe_repo_path(dir, "app.rb")
    end
  end

  def finding_without_snippet
    Hive::Patrol::Finding.new(
      id: "f1", feature_id: "route-users", category: "bug", severity: "high",
      confidence: "medium", title: "Nil user crash",
      description: "The route crashes on nil user", recommendation: "Guard nil user",
      evidence: [ { "file" => "../outside.rb", "line" => 1 } ]
    )
  end

  def test_traversal_evidence_does_not_read_out_of_tree_file
    Dir.mktmpdir do |parent|
      project = File.join(parent, "repo")
      FileUtils.mkdir_p(project)
      outside = File.join(parent, "outside.rb")

      File.write(outside, "first-content\n")
      first = Hive::Patrol::Fingerprint.compute(finding_without_snippet, project_root: project)

      File.write(outside, "totally-different\n")
      second = Hive::Patrol::Fingerprint.compute(finding_without_snippet, project_root: project)

      assert_equal first, second,
                   "snippet anchor must not read files outside the project root"
    end
  end

  def test_snippet_at_reads_context_and_handles_missing_files
    with_tmp_dir do |dir|
      File.write(File.join(dir, "app.rb"), "a\nb\nc\n")

      assert_equal "a b c", Hive::Patrol::Fingerprint.snippet_at(dir, "app.rb", 2)
      assert_equal "", Hive::Patrol::Fingerprint.snippet_at(dir, "missing.rb", 1)
    end
  end

  # ── similarity dedup ───────────────────────────────────────────────────

  def titled(title, category: "security")
    Hive::Patrol::Finding.new(
      id: "f1", feature_id: "f", category: category, severity: "high",
      confidence: "high", title: title, description: "d", recommendation: "r",
      evidence: [ { "file" => "bin/x", "line" => 1, "snippet" => "x" } ]
    )
  end

  def recorded(title, category: "security", state: "merged")
    { "state" => state, "category" => category,
      "title_tokens" => Hive::Patrol::Fingerprint.title_tokens(titled(title, category: category)) }
  end

  def test_record_seen_stores_content_when_finding_given
    fps = {}
    Hive::Patrol::Fingerprint.record_seen(fps, "fp1", state: "open",
                                          finding: titled("Dry-run gh allows implicit POST mutations"))
    assert_equal "security", fps["fp1"]["category"]
    assert_includes fps["fp1"]["title_tokens"], "implicit"
  end

  def test_similar_known_matches_reworded_finding_in_same_category
    # An already-merged finding, re-worded on a later scan, must be skipped.
    fps = { "old" => recorded("Dry-run gh API stub allows implicit POST mutations") }
    new_finding = titled("Dry-run gh api allows implicit POST requests")

    assert Hive::Patrol::Fingerprint.similar_known?(fps, {}, new_finding),
           "a re-worded same-category finding must be recognised as already known"
  end

  def test_similar_known_also_checks_dismissed
    dismissed = { "old" => recorded("Dry-run gh dry-run check misses implicit POST requests") }
    new_finding = titled("Dry-run gh API stub allows implicit POST mutations")

    assert Hive::Patrol::Fingerprint.similar_known?({}, dismissed, new_finding)
  end

  def test_similar_known_respects_category
    fps = { "old" => recorded("allows implicit POST requests", category: "bug") }
    new_finding = titled("allows implicit POST requests", category: "security")

    refute Hive::Patrol::Fingerprint.similar_known?(fps, {}, new_finding),
           "a different category is a different finding even with identical wording"
  end

  def test_similar_known_ignores_non_active_states_and_unrelated_titles
    seen_only = { "x" => recorded("allows implicit POST requests", state: "seen") }
    refute Hive::Patrol::Fingerprint.similar_known?(seen_only, {}, titled("allows implicit POST requests")),
           "a merely-seen (never PR'd) finding does not gate"

    unrelated = { "y" => recorded("Sandbox tree leaks the top-level .git directory") }
    refute Hive::Patrol::Fingerprint.similar_known?(unrelated, {}, titled("allows implicit POST requests"))
  end

  def test_overlap_coefficient
    assert_in_delta 1.0, Hive::Patrol::Fingerprint.overlap_coefficient(%w[a b], %w[a b c]), 0.001
    assert_in_delta 0.5, Hive::Patrol::Fingerprint.overlap_coefficient(%w[a x], %w[a b]), 0.001
    assert_equal 0.0, Hive::Patrol::Fingerprint.overlap_coefficient([], %w[a])
  end
end
