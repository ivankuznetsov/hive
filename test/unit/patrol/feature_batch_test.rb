require "test_helper"
require "hive/patrol/feature"
require "hive/patrol/feature_batch"
require "hive/patrol/state_store"

class HivePatrolFeatureBatchTest < Minitest::Test
  include HiveTestHelper

  def features(count)
    (1..count).map do |index|
      Hive::Patrol::Feature.new(
        id: format("feature-%02d", index), kind: "architecture",
        entrypoints: [], owned_files: [], context_files: [], tests: []
      )
    end.reverse
  end

  def test_selects_deterministic_contiguous_batches_for_the_same_sha
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      selector = Hive::Patrol::FeatureBatch.new(
        cfg: { "patrol" => { "max_features_per_cycle" => 2 } }, state: state
      )

      first = selector.call(features(5), target_sha: "sha-1")
      state.update_state("feature_review_sha" => "sha-1", "feature_review_cursor" => first.next_cursor)
      second = selector.call(features(5), target_sha: "sha-1")
      state.update_state("feature_review_sha" => "sha-1", "feature_review_cursor" => second.next_cursor)
      third = selector.call(features(5), target_sha: "sha-1")

      assert_equal %w[feature-01 feature-02], first.features.map(&:id)
      assert_equal %w[feature-03 feature-04], second.features.map(&:id)
      assert_equal [ "feature-05" ], third.features.map(&:id)
      refute first.complete
      refute second.complete
      assert third.complete
      assert_equal 0, third.next_cursor
    end
  end

  def test_new_sha_and_out_of_range_cursor_restart_the_sweep
    with_tmp_dir do |dir|
      state = Hive::Patrol::StateStore.new(dir)
      state.update_state("feature_review_sha" => "old", "feature_review_cursor" => 99)
      selector = Hive::Patrol::FeatureBatch.new(
        cfg: { "patrol" => { "max_features_per_cycle" => 2 } }, state: state
      )

      result = selector.call(features(3), target_sha: "new")

      assert_equal %w[feature-01 feature-02], result.features.map(&:id)
      refute result.complete
    end
  end

  def test_empty_and_small_maps_complete_in_one_batch
    with_tmp_dir do |dir|
      selector = Hive::Patrol::FeatureBatch.new(
        cfg: { "patrol" => { "max_features_per_cycle" => 12 } },
        state: Hive::Patrol::StateStore.new(dir)
      )

      assert selector.call([], target_sha: "sha").complete
      result = selector.call(features(2), target_sha: "sha")
      assert result.complete
      assert_equal 2, result.features.length
    end
  end
end
