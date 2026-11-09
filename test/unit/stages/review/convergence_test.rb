require "test_helper"
require "tmpdir"
require "hive/stages/review"
require "hive/reviewers"

# Review-loop convergence: later passes fix only evidenced High findings,
# defer the rest, never accept release-evidence gates, and a verify-only
# pass reports only unresolved or regressed findings.
class ReviewConvergenceTest < Minitest::Test
  Convergence = Hive::Stages::Review::Convergence

  def cfg(max_passes: 2, gate: 2)
    { "review" => { "max_passes" => max_passes, "severity_gate_from_pass" => gate } }
  end

  def make_ctx(worktree, task_folder, pass:)
    Hive::Reviewers::Context.new(
      worktree_path: worktree, task_folder: task_folder, default_branch: "main", pass: pass
    )
  end

  def test_shipped_defaults_converge_after_two_fix_passes
    defaults = Hive::Config::DEFAULTS
    assert_equal 2, defaults.dig("review", "max_passes")
    assert_equal 2, defaults.dig("review", "severity_gate_from_pass")
  end

  def test_severity_gate_starts_at_the_configured_pass_and_can_be_disabled
    refute Convergence.severity_gated?(cfg, 1)
    assert Convergence.severity_gated?(cfg, 2)
    refute Convergence.severity_gated?(cfg(gate: nil), 5)
  end

  def test_verify_only_is_the_pass_beyond_max_passes
    refute Convergence.verify_only?(cfg, 2)
    assert Convergence.verify_only?(cfg, 3)
  end

  def test_reviewer_section_always_bans_release_evidence_findings
    text = Convergence.reviewer_section(cfg, 1)
    assert_includes text, "Do not report release-evidence gates"
    refute_includes text, "VERIFY-ONLY"
  end

  def test_verify_only_reviewer_section_limits_scope_to_unresolved_and_regressions
    text = Convergence.reviewer_section(cfg, 3)
    assert_includes text, "VERIFY-ONLY"
    assert_includes text, "unresolved from earlier passes"
    assert_includes text, "regressions introduced by the latest fix commits"
  end

  def test_later_reviewer_section_prioritizes_evidenced_high_findings
    text = Convergence.reviewer_section(cfg, 2)
    assert_includes text, "Prioritize regressions and High-severity defects"
    refute_includes text, "VERIFY-ONLY"
  end

  def test_triage_section_rejects_on_merit_and_defers_below_high_in_later_passes
    first = Convergence.triage_section(cfg, 1)
    assert_includes first, "Release-evidence gates are RESOLVED/NO-FIX"
    assert_includes first, "Reject on merit"
    refute_includes first, "Severity gate"

    later = Convergence.triage_section(cfg, 2)
    assert_includes later, "Severity gate"
    assert_includes later, "- [x] DEFERRED:"

    verify = Convergence.triage_section(cfg, 3)
    assert_includes verify, "out of verify-only scope"
  end

  def test_triage_and_reviewer_templates_render_the_convergence_rules
    %w[triage_courageous.md.erb triage_safetyist.md.erb].each do |name|
      source = File.read(File.expand_path("../../../../templates/#{name}", __dir__))
      assert_includes source, "<%= convergence_section %>", name
      assert_includes source, "DEFERRED", name
    end
    Dir[File.expand_path("../../../../templates/reviewer_*.md.erb", __dir__)].each do |path|
      assert_includes File.read(path), "<%= review_policy_section %>", File.basename(path)
    end
  end

  def test_deferred_findings_do_not_trigger_a_fix_pass
    assert Hive::Stages::Review.auto_fix_finding_line?("- [x] AUTO-FIX: real bug\n")
    refute Hive::Stages::Review.auto_fix_finding_line?("- [x] DEFERRED: edge case <!-- triage: medium -->\n")
  end

  def test_deferred_only_pass_has_no_accepted_findings
    Dir.mktmpdir do |dir|
      task_folder = File.join(dir, "task")
      FileUtils.mkdir_p(File.join(task_folder, "reviews"))
      File.write(File.join(task_folder, "reviews", "sol-ce-code-review-02.md"), <<~MD)
        ## Medium
        - [x] DEFERRED: tighten an unlikely input <!-- triage: severity gate -->
      MD
      payload = Hive::Stages::Review.collect_accepted_findings_with_count(make_ctx(dir, task_folder, pass: 2))
      assert_equal 0, payload.count
    end
  end

  def test_deferred_summary_collects_every_pass_and_is_removed_when_empty
    Dir.mktmpdir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "sol-ce-code-review-02.md"),
                 "- [x] DEFERRED: tighten an unlikely input <!-- triage: severity gate -->\n" \
                 "- [x] AUTO-FIX: real bug\n")
      File.write(File.join(reviews, "astra-adversarial-review-03.md"),
                 "- [x] DEFERRED: harden a local file read\n")

      assert_equal 2, Convergence.write_deferred_summary!(dir)
      summary = File.read(File.join(reviews, Convergence::DEFERRED_SUMMARY))
      assert_includes summary, "- tighten an unlikely input (sol-ce-code-review-02)"
      assert_includes summary, "- harden a local file read (astra-adversarial-review-03)"
      assert_includes summary, "do not file another follow-up"
      refute_includes summary, "real bug"

      File.write(File.join(reviews, "sol-ce-code-review-02.md"), "- [x] AUTO-FIX: real bug\n")
      File.write(File.join(reviews, "astra-adversarial-review-03.md"), "")
      assert_equal 0, Convergence.write_deferred_summary!(dir)
      refute File.exist?(File.join(reviews, Convergence::DEFERRED_SUMMARY))
    end
  end
end
