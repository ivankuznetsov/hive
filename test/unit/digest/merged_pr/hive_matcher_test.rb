require "test_helper"
require "hive/digest/merged_pr/hive_matcher"

class HiveDigestMergedPrHiveMatcherTest < Minitest::Test
  include HiveTestHelper

  def test_matches_hive_branch_slug_to_stage
    with_tmp_dir do |dir|
      state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(File.join(state, "stages", "9-done", "task-260613-abcd"))
      matcher = Hive::Digest::MergedPr::HiveMatcher.new(
        registry: -> { [ { "hive_state_path" => state } ] },
        logger: nil
      )

      match = matcher.match("hive/task-260613-abcd")

      assert_equal({ slug: "task-260613-abcd", stage: "9-done" }, match)
    end
  end

  def test_non_hive_branch_does_not_match
    matcher = Hive::Digest::MergedPr::HiveMatcher.new(registry: -> { raise "not called" }, logger: nil)

    assert_nil matcher.match("feature")
  end

  def test_registry_entry_failure_is_warned_and_skipped
    io = StringIO.new
    logger = Logger.new(io)
    matcher = Hive::Digest::MergedPr::HiveMatcher.new(
      registry: -> { [ {}, { "hive_state_path" => "/tmp/missing" } ] },
      logger: logger
    )

    assert_nil matcher.match("hive/task-260613-abcd")
    assert_match(/Hive match skipped/, io.string)
  end

  def test_registry_failure_returns_nil
    io = StringIO.new
    logger = Logger.new(io)
    matcher = Hive::Digest::MergedPr::HiveMatcher.new(
      registry: -> { raise "registry unavailable" },
      logger: logger
    )

    assert_nil matcher.match("hive/task-260613-abcd")
    assert_match(/Hive match failed/, io.string)
  end
end
