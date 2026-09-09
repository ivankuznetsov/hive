require "test_helper"
require_relative "../support/test_partition"

class TestPartitionTest < Minitest::Test
  def test_runtime_balancing_is_deterministic_and_complete
    Dir.mktmpdir do |dir|
      path = File.join(dir, "times.json")
      File.write(path, JSON.generate(schema: "hive-shard-timings.v1", seconds_per_run: { "a" => 10, "b" => 6, "c" => 4 }))
      expected = [ [ "a" ], [ "b", "c" ] ]
      assert_equal expected, HiveTestPartition.partition(%w[a b c], count: 2, timings_path: path)
      assert_equal expected, HiveTestPartition.partition(%w[c b a], count: 2, timings_path: path)
      shards = HiveTestPartition.partition(%w[a b c new], count: 2, timings_path: path)
      assert_equal %w[a b c new], shards.flatten.sort
      assert_equal [ [ "a", "c" ], [ "b", "new" ] ], shards
    end
  end

  def test_missing_corrupt_and_invalid_timings_fall_back_without_dropping_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, "times.json")
      [ nil, "not json", "[]", JSON.generate(schema: "hive-shard-timings.v1", seconds_per_run: { "a" => -1, "b" => "slow", "c" => 100_000 }) ].each do |contents|
        File.write(path, contents) if contents
        assert_equal [ [ "a", "c" ], [ "b" ] ], HiveTestPartition.partition(%w[c b a], count: 2, timings_path: path)
      end
    end
  end

  def test_missing_timings_use_file_bytes
    Dir.mktmpdir do |root|
      { "a" => 10, "b" => 6, "c" => 4 }.each { |name, size| File.write(File.join(root, name), "x" * size) }
      assert_equal [ [ "a" ], [ "b", "c" ] ], HiveTestPartition.partition(%w[a b c], count: 2, root: root, timings_path: File.join(root, "missing"))
    end
  end

  def test_invalid_partition_and_duplicate_manifest_fail_closed
    assert_raises(ArgumentError) { HiveTestPartition.partition([ "a" ], count: 0) }
    assert_raises(ArgumentError) { HiveTestPartition.partition(%w[a a], count: 2) }
  end
end
