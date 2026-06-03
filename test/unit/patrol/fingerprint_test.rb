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
end
