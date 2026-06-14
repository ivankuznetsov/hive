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
