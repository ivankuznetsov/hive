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

  def test_structured_root_cause_fingerprint_is_feature_and_wording_independent
    with_tmp_dir do |dir|
      File.write(File.join(dir, "lib.rb"), "dispatch(item)\n")
      first = finding
      first.feature_id = "command-cli"
      first.title = "Queue stalls after a rejected launch"
      first.contract = "Rejected dispatches must remain retryable."
      first.root_cause = "The scheduler lease remains claimed when launch is gated."
      first.evidence = [ { "file" => "lib.rb", "line" => 1, "snippet" => "dispatch(item)" } ]
      second = finding
      second.feature_id = "architecture-lib-scheduler"
      second.title = "Pending work never retries"
      second.contract = "Rejected dispatches must remain retryable."
      second.root_cause = "The scheduler lease remains claimed when launch is gated."
      second.evidence = [ { "file" => "lib.rb", "line" => 1, "snippet" => "different anchor" } ]

      first_fingerprint = Hive::Patrol::Fingerprint.compute(first, project_root: dir)
      second_fingerprint = Hive::Patrol::Fingerprint.compute(second, project_root: dir)

      assert_equal first_fingerprint, second_fingerprint
    end
  end

  def test_structured_root_cause_changes_semantic_fingerprint
    with_tmp_dir do |dir|
      File.write(File.join(dir, "lib.rb"), "dispatch(item)\n")
      lease = finding
      lease.contract = "Rejected dispatches must remain retryable."
      lease.root_cause = "The scheduler lease remains claimed after a gate."
      lease.evidence = [ { "file" => "lib.rb", "line" => 1, "snippet" => "dispatch(item)" } ]
      cache = finding
      cache.contract = lease.contract
      cache.root_cause = "The result cache evicts work before acknowledgement."
      cache.evidence = lease.evidence

      refute_equal Hive::Patrol::Fingerprint.compute(lease, project_root: dir),
                   Hive::Patrol::Fingerprint.compute(cache, project_root: dir)
    end
  end

  def test_structured_exact_fingerprint_is_wording_sensitive_but_similarity_is_fuzzy
    with_tmp_dir do |dir|
      File.write(File.join(dir, "lib.rb"), "dispatch(item)\n")
      first = finding
      first.contract = "Rejected dispatches must remain retryable."
      first.root_cause = "External launcher options bypass the read-only execution policy."
      first.evidence = [ { "file" => "lib.rb", "line" => 1 } ]
      second = finding
      second.contract = "A rejected dispatch remains eligible for retry."
      second.root_cause = "The read only execution policy is bypassed by external launcher options."
      second.evidence = first.evidence

      refute_equal Hive::Patrol::Fingerprint.compute(first, project_root: dir),
                   Hive::Patrol::Fingerprint.compute(second, project_root: dir)

      fingerprints = {}
      Hive::Patrol::Fingerprint.record_seen(fingerprints, "old", state: "merged", finding: first)
      assert Hive::Patrol::Fingerprint.similar_known?(fingerprints, {}, second)
    end
  end

  # ── compatibility pins ─────────────────────────────────────────────────
  # These exact digests were computed once by running the current
  # implementation and are hard-coded on purpose: the fingerprint ledger
  # (.hive-state/patrol/fingerprints.json) is durable, so ANY accidental
  # change to the payload composition, join order, or normalize_token in
  # Fingerprint.compute silently orphans every existing dedup/dismissal/PR
  # entry. If one of these fails, you are changing the on-disk identity
  # contract — migrate the ledger deliberately or revert.

  def test_pinned_structured_v2_fingerprint_digest
    with_tmp_dir do |dir|
      structured = Hive::Patrol::Finding.new(
        id: "f1", feature_id: "route-users", category: "bug", severity: "high",
        confidence: "medium", title: "Queue handoff loses accepted jobs",
        description: "The queue drops accepted jobs during handoff.",
        recommendation: "Acknowledge before clearing durable state.",
        contract: "Accepted jobs must be delivered exactly once.",
        root_cause: "The handoff clears durable state before acknowledgement.",
        evidence: [ { "file" => "lib/queue.rb", "line" => 10, "snippet" => "state.delete(id)" } ]
      )

      assert_equal "29ea35b6d720bf18bedcf34a427468e635dd0d5af438e4cbeeee1cf11b07b998",
                   Hive::Patrol::Fingerprint.compute(structured, project_root: dir)
    end
  end

  def test_pinned_legacy_v1_fallback_fingerprint_digest
    with_tmp_dir do |dir|
      # `finding` carries no contract/root_cause, so compute takes the
      # legacy feature_id + category + path + snippet-token branch.
      assert_equal "41aca36f53d5d255b54b567d6191411559133a351e3b6d0c5eb51d269c6d5134",
                   Hive::Patrol::Fingerprint.compute(finding, project_root: dir)
    end
  end

  def test_feature_history_matches_grouped_and_component_legacy_aliases
    scripts = finding
    scripts.feature_id = "command-package-json-scripts"
    scripts.evidence = [ { "file" => "package.json", "line" => 1 } ]
    python_scripts = finding
    python_scripts.feature_id = "command-pyproject-scripts"
    swift_executables = finding
    swift_executables.feature_id = "command-package-swift-executables"
    route = finding
    route.feature_id = "architecture-pages"
    route.evidence = [ { "file" => "pages/users.tsx", "line" => 1 } ]
    package = finding
    package.feature_id = "architecture-manifest-project"
    package.evidence = [ { "file" => "Gemfile", "line" => 1 } ]

    assert Hive::Patrol::Fingerprint.same_feature_history?("command-npm-script-test", scripts)
    assert Hive::Patrol::Fingerprint.same_feature_history?("command-python-script-lint", python_scripts)
    assert Hive::Patrol::Fingerprint.same_feature_history?("command-swift-executable-cli", swift_executables)
    assert Hive::Patrol::Fingerprint.same_feature_history?("route-pages-users-tsx", route)
    assert Hive::Patrol::Fingerprint.same_feature_history?("package-gemfile", package)
    refute Hive::Patrol::Fingerprint.same_feature_history?("route-pages-admin-tsx", route)
  end

  def test_feature_history_rejects_empty_unrelated_and_unanchored_ids
    command = finding
    command.feature_id = "command-bin-tool"
    component_without_evidence = finding
    component_without_evidence.feature_id = "architecture-lib-runtime"
    component_without_evidence.evidence = []

    refute Hive::Patrol::Fingerprint.same_feature_history?("", command)
    refute Hive::Patrol::Fingerprint.same_feature_history?("route-bin-tool", command)
    refute Hive::Patrol::Fingerprint.same_feature_history?("route-lib-runtime-rb", component_without_evidence)
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
      File.write(File.join(dir, "empty.rb"), "")

      assert_equal "a b c", Hive::Patrol::Fingerprint.snippet_at(dir, "app.rb", 2)
      assert_equal "", Hive::Patrol::Fingerprint.snippet_at(dir, "missing.rb", 1)
      assert_equal "", Hive::Patrol::Fingerprint.snippet_at(dir, "app.rb", 1_000_000)
      assert_equal "", Hive::Patrol::Fingerprint.snippet_at(dir, "empty.rb", 3)
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
    finding = titled("Dry-run gh allows implicit POST mutations")
    finding.root_cause = "Payload flags silently change a read into a write"
    finding.target_sha = "a" * 40
    Hive::Patrol::Fingerprint.record_seen(fps, "fp1", state: "open", finding: finding)
    assert_equal "security", fps["fp1"]["category"]
    assert_equal "f", fps["fp1"]["feature_id"]
    assert_equal "a" * 40, fps["fp1"]["target_sha"]
    assert_includes fps["fp1"]["title_tokens"], "implicit"
    assert_includes fps["fp1"]["root_cause_tokens"], "payload"
  end

  def test_similar_known_matches_shared_root_cause_when_titles_drift
    known = titled("Browser process can escape the guard")
    known.root_cause = "External launcher options bypass the read-only execution policy"
    fps = {}
    Hive::Patrol::Fingerprint.record_seen(fps, "old", state: "merged", finding: known)
    candidate = titled("Pager flag is accepted")
    candidate.root_cause = "Read only execution policy is bypassed by external launcher options"

    assert Hive::Patrol::Fingerprint.similar_known?(fps, {}, candidate)
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
