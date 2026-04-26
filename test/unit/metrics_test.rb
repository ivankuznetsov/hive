require "test_helper"
require "hive/metrics"

# Direct coverage for the rollback-rate metric. Builds tmp git repos
# with hive-fix-trailered commits and Revert followers, asserts the
# parser counts what we expect.
class MetricsTest < Minitest::Test
  include HiveTestHelper

  def commit_with(dir, file:, content:, subject:, trailers: {})
    File.write(File.join(dir, file), content)
    run!("git", "-C", dir, "add", file)
    body = trailers.map { |k, v| "#{k}: #{v}" }.join("\n")
    msg = body.empty? ? subject : "#{subject}\n\n#{body}\n"
    run!("git", "-C", dir, "commit", "-m", msg, "--quiet")
    `git -C #{dir} rev-parse HEAD`.strip
  end

  def test_returns_zero_when_no_fix_commits
    with_tmp_git_repo do |dir|
      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 0, stats["total_fix_commits"]
      assert_equal 0, stats["reverted_commits"]
      assert_in_delta 0.0, stats["rollback_rate"]
    end
  end

  def test_counts_fix_commits_by_trailer
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(a): one",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Triage-Bias" => "courageous", "Hive-Fix-Phase" => "fix" })
      commit_with(dir, file: "b.rb", content: "2\n", subject: "fix(b): two",
                  trailers: { "Hive-Fix-Pass" => "02", "Hive-Triage-Bias" => "safetyist", "Hive-Fix-Phase" => "fix" })
      commit_with(dir, file: "c.rb", content: "3\n", subject: "feat(c): unrelated") # no trailer

      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 2, stats["total_fix_commits"]
      assert_equal 0, stats["reverted_commits"]
      assert_equal 1, stats["by_bias"]["courageous"]["total"]
      assert_equal 1, stats["by_bias"]["safetyist"]["total"]
      assert_equal 2, stats["by_phase"]["fix"]["total"]
    end
  end

  def test_detects_revert_by_subject_match
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: %(fix(a): targeted),
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Triage-Bias" => "courageous", "Hive-Fix-Phase" => "fix" })
      # Simulate a Revert commit
      File.delete(File.join(dir, "a.rb"))
      run!("git", "-C", dir, "add", "-A")
      run!("git", "-C", dir, "commit", "-m", %(Revert "fix(a): targeted"), "--quiet")

      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats["total_fix_commits"]
      assert_equal 1, stats["reverted_commits"]
      assert_in_delta 1.0, stats["rollback_rate"]
      assert_equal 1, stats["by_bias"]["courageous"]["reverted"]
    end
  end

  def test_detects_revert_by_sha_in_body
    with_tmp_git_repo do |dir|
      sha = commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(a): one",
                        trailers: { "Hive-Fix-Pass" => "01", "Hive-Triage-Bias" => "courageous", "Hive-Fix-Phase" => "fix" })
      File.delete(File.join(dir, "a.rb"))
      run!("git", "-C", dir, "add", "-A")
      msg = "Revert manually applied\n\nThis reverts commit #{sha}.\n"
      run!("git", "-C", dir, "commit", "-m", msg, "--quiet")

      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats["reverted_commits"]
    end
  end

  def test_separates_ci_phase_from_fix_phase
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(ci): one",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Fix-Phase" => "ci" })
      commit_with(dir, file: "b.rb", content: "2\n", subject: "fix(b): two",
                  trailers: { "Hive-Fix-Pass" => "02", "Hive-Fix-Phase" => "fix" })

      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats["by_phase"]["ci"]["total"]
      assert_equal 1, stats["by_phase"]["fix"]["total"]
    end
  end

  def test_unknown_bias_bucketed_separately
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(a): one",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Fix-Phase" => "fix" })
      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats["by_bias"]["unknown"]["total"]
    end
  end

  def test_raises_when_project_root_missing
    assert_raises(ArgumentError) do
      Hive::Metrics.rollback_rate("/no/such/path/here")
    end
  end

  # --- R4: reverted? prefix-collision false positive --------------------

  def test_reverted_does_not_false_positive_on_shared_seven_char_prefix
    # Two commits sharing the same 7-char prefix but DIFFERENT full SHAs.
    # A Revert citing only the first commit's full SHA must NOT mark the
    # second commit as reverted.
    fix_a_sha = "abcdef0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    fix_b_sha = "abcdef0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    fix_a = { sha: fix_a_sha, subject: "fix(a): one", body: "" }
    fix_b = { sha: fix_b_sha, subject: "fix(b): two", body: "" }

    revert_subjects = {} # no subject matches
    # Revert cites fix_a's FULL sha — only fix_a should be considered reverted.
    revert_shas = { fix_a_sha => [ "rev1234567890" ] }

    assert Hive::Metrics.reverted?(fix_a, revert_subjects, revert_shas),
           "the cited fix commit must be detected as reverted"
    refute Hive::Metrics.reverted?(fix_b, revert_subjects, revert_shas),
           "an unrelated fix sharing only the first 7 chars must NOT be detected as reverted"
  end

  def test_reverted_handles_short_sha_prefix_in_revert_body
    # `This reverts commit <short>` is allowed to cite a 7+ char prefix.
    # The fix commit's full SHA must START with the cited prefix for the
    # match to count.
    fix = { sha: "abcdef01234567890123456789012345678901ab", subject: "fix(x)", body: "" }
    revert_shas = { "abcdef0" => [ "rev1" ] } # 7-char prefix of fix
    assert Hive::Metrics.reverted?(fix, {}, revert_shas)
  end

  # ── revert-of-revert and duplicate-revert contract pinning ──────────

  def test_revert_of_revert_re_counts_original_as_active
    # Sequence: trailered fix(A), Revert "fix(A)" (B), Revert "Revert ..." (C).
    # The current implementation's `reverted?` matches a fix commit's
    # subject against any Revert subject in the log; with B present, A
    # is still flagged as reverted regardless of C resurrecting it.
    # This test pins the current behaviour so a future tightening
    # (revert-of-revert chain detection) explicitly bumps the contract.
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(a): targeted",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Triage-Bias" => "courageous", "Hive-Fix-Phase" => "fix" })
      # B reverts A.
      File.delete(File.join(dir, "a.rb"))
      run!("git", "-C", dir, "add", "-A")
      run!("git", "-C", dir, "commit", "-m", %(Revert "fix(a): targeted"), "--quiet")
      # C reverts B (i.e. revives A's diff).
      File.write(File.join(dir, "a.rb"), "1\n")
      run!("git", "-C", dir, "add", "-A")
      run!("git", "-C", dir, "commit", "-m", %(Revert "Revert \\"fix(a): targeted\\""), "--quiet")

      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats["total_fix_commits"]
      # Pin the current behaviour: A still counts as reverted because
      # B's Revert subject matches A's subject. A future revert-of-
      # revert resolver would flip this to 0; either way the contract
      # is pinned and a silent drift fails this test.
      assert_equal 1, stats["reverted_commits"],
                   "current behaviour: A is still marked reverted even after C resurrects it"
    end
  end

  def test_multiple_reverts_of_same_commit_count_once
    # Two Revert commits both citing fix(A). The metric counts per fix
    # commit, not per revert: A is reverted (count=1), regardless of
    # how many Reverts cited it.
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(a): one",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Triage-Bias" => "courageous", "Hive-Fix-Phase" => "fix" })
      # First Revert.
      File.delete(File.join(dir, "a.rb"))
      run!("git", "-C", dir, "add", "-A")
      run!("git", "-C", dir, "commit", "-m", %(Revert "fix(a): one"), "--quiet")
      # Second Revert citing the same subject (e.g. someone re-ran the
      # revert workflow against a force-pushed branch). Use `--allow-empty`
      # because the diff is already applied.
      run!("git", "-C", dir, "commit", "--allow-empty", "-m",
           %(Revert "fix(a): one"), "--quiet")

      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats["total_fix_commits"]
      assert_equal 1, stats["reverted_commits"],
                   "duplicate Reverts of the same fix commit must count once, not twice"
      assert_in_delta 1.0, stats["rollback_rate"]
    end
  end

  def test_since_filter_excludes_old_commits
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(a): old",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Fix-Phase" => "fix" })
      # since=now should exclude every commit
      stats = Hive::Metrics.rollback_rate(dir, since: "1 second ago")
      # The just-made commit may or may not fall outside "1 second ago" depending on
      # filesystem clock; use 100 years instead — guaranteed exclusion.
      stats = Hive::Metrics.rollback_rate(dir, since: "100 years from now")
      # git treats `100 years from now` as in the future and yields no commits
      assert_equal 0, stats["total_fix_commits"]
    end
  end
end
