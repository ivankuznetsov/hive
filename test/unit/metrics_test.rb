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
      assert_equal 0, stats[:total_fix_commits]
      assert_equal 0, stats[:reverted_commits]
      assert_in_delta 0.0, stats[:rollback_rate]
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
      assert_equal 2, stats[:total_fix_commits]
      assert_equal 0, stats[:reverted_commits]
      assert_equal 1, stats[:by_bias]["courageous"][:total]
      assert_equal 1, stats[:by_bias]["safetyist"][:total]
      assert_equal 2, stats[:by_phase]["fix"][:total]
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
      assert_equal 1, stats[:total_fix_commits]
      assert_equal 1, stats[:reverted_commits]
      assert_in_delta 1.0, stats[:rollback_rate]
      assert_equal 1, stats[:by_bias]["courageous"][:reverted]
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
      assert_equal 1, stats[:reverted_commits]
    end
  end

  def test_separates_ci_phase_from_fix_phase
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(ci): one",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Fix-Phase" => "ci" })
      commit_with(dir, file: "b.rb", content: "2\n", subject: "fix(b): two",
                  trailers: { "Hive-Fix-Pass" => "02", "Hive-Fix-Phase" => "fix" })

      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats[:by_phase]["ci"][:total]
      assert_equal 1, stats[:by_phase]["fix"][:total]
    end
  end

  def test_unknown_bias_bucketed_separately
    with_tmp_git_repo do |dir|
      commit_with(dir, file: "a.rb", content: "1\n", subject: "fix(a): one",
                  trailers: { "Hive-Fix-Pass" => "01", "Hive-Fix-Phase" => "fix" })
      stats = Hive::Metrics.rollback_rate(dir)
      assert_equal 1, stats[:by_bias]["unknown"][:total]
    end
  end

  def test_raises_when_project_root_missing
    assert_raises(ArgumentError) do
      Hive::Metrics.rollback_rate("/no/such/path/here")
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
      assert_equal 0, stats[:total_fix_commits]
    end
  end
end
