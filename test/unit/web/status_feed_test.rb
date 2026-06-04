require "test_helper"
require "hive/web/status_feed"

class StatusFeedTest < Minitest::Test
  include HiveTestHelper

  def test_snapshot_uses_registered_projects
    with_tmp_global_config do
      feed = Hive::Web::StatusFeed.new
      payload = feed.snapshot

      assert_equal "hive-status", payload["schema"]
      assert_equal [], payload["projects"]
    end
  end
end
