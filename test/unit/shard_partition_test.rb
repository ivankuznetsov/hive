require "test_helper"
require_relative "../support/shard_partition"

module TestShardPartition
  class RuntimePartitionTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir("shard-partition")
    end

    def teardown
      FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
    end
    def test_greedy_runtime_partition_balances_total_seconds_across_shards
      files = 12.times.map { |index| "test/unit/f#{index}_test.rb" }
      timings = files.each_with_index.to_h { |file, index| [ file, (index % 4 + 1) * 10.0 ] }

      shards = HiveShardPartition.partition(files: files, count: 3, timings: timings)

      assert_equal 3, shards.length
      loads = shards.map { |shard| shard.sum { |file| timings.fetch(file) } }
      assert_operator(loads.max - loads.min, :<=, 10.0, "loads within one heaviest file: #{loads.inspect}")
    end

    def test_partition_is_deterministic_and_complete_and_disjoint
      files = %w[test/unit/b_test.rb test/unit/a_test.rb test/unit/c_test.rb]
      timings = { "test/unit/a_test.rb" => 5.0, "test/unit/b_test.rb" => 1.0 }

      first = HiveShardPartition.partition(files: files, count: 2, timings: timings)
      second = HiveShardPartition.partition(files: files, count: 2, timings: timings)

      assert_equal first, second
      assert_equal files.sort, first.flatten.sort
      assert_equal files.length, first.flatten.uniq.length
    end

    def test_files_absent_from_timings_still_get_assigned_with_zero_weight
      shards = HiveShardPartition.partition(
        files: [ "test/unit/known_test.rb", "test/unit/unknown_test.rb" ],
        count: 2,
        timings: { "test/unit/known_test.rb" => 30.0 }
      )

      assert_equal [ [ "test/unit/known_test.rb" ], [ "test/unit/unknown_test.rb" ] ].map(&:sort),
                   shards.map(&:sort)
    end

    def test_missing_or_empty_or_malformed_timings_fall_back_to_bytes
      files = 6.times.map do |index|
        path = File.join(@dir, "f#{index}_test.rb")
        File.write(path, "x" * (100 * (index + 1)))
        path
      end

      [ nil, {}, "not-a-hash" ].each do |timings|
        shards = HiveShardPartition.partition(files: files, count: 2, timings: timings)

        assert_equal 2, shards.length
        assert_equal files.sort, shards.flatten.sort
      end
    end

    def test_byte_size_hot_tail_fallback_matches_the_historical_six_way_shape
      files = 24.times.map do |index|
        path = File.join(@dir, "f#{index}_test.rb")
        File.write(path, "x" * (50 * (index + 1)))
        path
      end

      shards = HiveShardPartition.by_bytes_hot_tail(files, 6)

      assert_equal 6, shards.length
      assert_equal files.sort, shards.flatten.sort
      assert_equal files.length, shards.flatten.uniq.length
    end

    def test_staleness_detection_flags_old_timings_files_only
      path = File.join(@dir, "timings.json")
      File.write(path, "{}")

      fresh = Time.now - (10 * 24 * 60 * 60)
      stale = Time.now - (20 * 24 * 60 * 60)
      File.utime(fresh, fresh, path)

      refute HiveShardPartition.stale?(path, now: Time.now)
      File.utime(stale, stale, path)
      assert HiveShardPartition.stale?(path, now: Time.now)
      refute HiveShardPartition.stale?(File.join(@dir, "missing.json"), now: Time.now)
    end
  end
end
