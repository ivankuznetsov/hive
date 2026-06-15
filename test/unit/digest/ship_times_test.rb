require "test_helper"
require "hive/digest/ship_times"

class HiveDigestShipTimesTest < Minitest::Test
  include HiveTestHelper

  def test_prefers_pr_finalized_over_archived
    with_state_repo do |repo|
      commit(repo, "2026-06-12T10:00:00Z", "hive: 9-done/demo-260612-abcd archived")
      commit(repo, "2026-06-12T09:00:00Z", "hive: 8-finalize/demo-260612-abcd pr_finalized")

      shipped_at = Hive::Digest::ShipTimes.new.shipped_at(
        hive_state_path: repo,
        slug: "demo-260612-abcd"
      )

      assert_equal Time.utc(2026, 6, 12, 9, 0, 0), shipped_at
    end
  end

  def test_falls_back_to_archived_then_approval_to_done
    with_state_repo do |repo|
      commit(repo, "2026-06-12T11:00:00Z", "hive: 9-done/fallback-260612-abcd archived")
      commit(repo, "2026-06-12T12:00:00Z", "hive: 8-finalize/approved-260612-abcd approve -> 9-done")

      resolver = Hive::Digest::ShipTimes.new

      assert_equal Time.utc(2026, 6, 12, 11, 0, 0),
                   resolver.shipped_at(hive_state_path: repo, slug: "fallback-260612-abcd")
      assert_equal Time.utc(2026, 6, 12, 12, 0, 0),
                   resolver.shipped_at(hive_state_path: repo, slug: "approved-260612-abcd")
    end
  end

  def test_returns_nil_when_no_matching_commit_exists
    with_state_repo do |repo|
      commit(repo, "2026-06-12T10:00:00Z", "hive: 9-done/other-260612-abcd archived")

      assert_nil Hive::Digest::ShipTimes.new.shipped_at(hive_state_path: repo, slug: "demo-260612-abcd")
    end
  end

  def test_matches_action_on_non_done_stage_via_suffix_fallback
    with_state_repo do |repo|
      # No "hive: 9-done/<slug> pr_finalized" exact commit exists, so the
      # finalize-stage commit must still match via the suffix fallback.
      commit(repo, "2026-06-12T08:00:00Z", "hive: 8-finalize/suffix-260612-abcd pr_finalized")

      assert_equal Time.utc(2026, 6, 12, 8, 0, 0),
                   Hive::Digest::ShipTimes.new.shipped_at(hive_state_path: repo, slug: "suffix-260612-abcd")
    end
  end

  def test_fixed_string_grep_tolerates_regex_metacharacters_in_slug
    with_state_repo do |repo|
      # An unbalanced '[' is an invalid regex; without -F the git --grep
      # would exit non-zero and the item would be silently dropped.
      slug = "weird-[260612-abcd"
      commit(repo, "2026-06-12T07:00:00Z", "hive: 9-done/#{slug} archived")

      assert_equal Time.utc(2026, 6, 12, 7, 0, 0),
                   Hive::Digest::ShipTimes.new.shipped_at(hive_state_path: repo, slug: slug)
    end
  end

  def test_raises_git_error_when_git_log_fails
    with_tmp_dir do |not_a_repo|
      error = assert_raises(Hive::GitError) do
        Hive::Digest::ShipTimes.new.shipped_at(hive_state_path: not_a_repo, slug: "demo-260612-abcd")
      end

      assert_match(/git log/, error.message)
    end
  end

  private

  def with_state_repo
    with_tmp_dir do |repo|
      run!("git", "-C", repo, "init", "-b", "hive/state", "--quiet")
      run!("git", "-C", repo, "config", "user.email", "test@example.com")
      run!("git", "-C", repo, "config", "user.name", "Test")
      run!("git", "-C", repo, "config", "commit.gpgsign", "false")
      File.write(File.join(repo, ".gitkeep"), "")
      run!("git", "-C", repo, "add", ".gitkeep")
      commit(repo, "2026-06-01T00:00:00Z", "hive: bootstrap")
      yield repo
    end
  end

  def commit(repo, timestamp, message)
    with_env("GIT_AUTHOR_DATE" => timestamp, "GIT_COMMITTER_DATE" => timestamp) do
      run!("git", "-C", repo, "commit", "--allow-empty", "-m", message, "--quiet")
    end
  end
end
