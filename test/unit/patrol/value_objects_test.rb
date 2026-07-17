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
      "scope" => "cross_feature",
      "contract" => "Requests must not dereference a missing user.",
      "impact" => "A valid request crashes before returning a response.",
      "root_cause" => "The shared request path assumes lookup always succeeds.",
      "reproduction" => "Call the route with an unknown user id.",
      "validation" => "Run the route regression and the request suite.",
      "alpha_score" => 87,
      "evidence" => [ { "file" => "app.rb" } ],
      "fingerprint" => "fp"
    )
    assert_equal "f1", finding.id
    assert_equal "fp", finding.fingerprint
    assert_equal "cross_feature", finding.scope
    assert_equal 87, finding.alpha_score
    assert_equal "Requests must not dereference a missing user.", finding.to_h.fetch("contract")
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
