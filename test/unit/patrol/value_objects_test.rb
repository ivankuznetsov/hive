require "test_helper"
require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/state_store"

class HivePatrolValueObjectsTest < Minitest::Test
  include HiveTestHelper

  def test_feature_and_finding_from_h_round_trip
    feature = Hive::Patrol::Feature.from_h(
      "id" => "route-home",
      "kind" => "route",
      "entrypoints" => [ "app.rb" ],
      "owned_files" => [ "app.rb" ],
      "context_files" => [ "README.md" ],
      "tests" => [ "test/app_test.rb" ]
    )
    assert_equal "route-home", feature.id
    assert_equal [ "app.rb" ], feature.entrypoints

    finding = Hive::Patrol::Finding.from_h(
      "id" => "f1",
      "feature_id" => "route-home",
      "category" => "bug",
      "severity" => "high",
      "confidence" => "medium",
      "title" => "Crash",
      "description" => "nil crash",
      "recommendation" => "guard",
      "evidence" => [ { "file" => "app.rb" } ],
      "fingerprint" => "fp"
    )
    assert_equal "f1", finding.id
    assert_equal "fp", finding.fingerprint
  end

  def test_state_store_non_hash_json_reads_as_empty
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      path = File.join(store.root, "state.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "[]")

      assert_equal({}, store.state)
    end
  end

  def test_state_store_malformed_json_reads_as_empty
    with_tmp_dir do |dir|
      store = Hive::Patrol::StateStore.new(dir)
      path = File.join(store.root, "state.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "[")

      assert_equal({}, store.state)
    end
  end
end
