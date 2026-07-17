require "test_helper"
require "hive/refactor_patrol/fingerprint"
require "hive/refactor_patrol/state_store"
require "hive/refactor_patrol/thesis"

class RefactorPatrolFingerprintTest < Minitest::Test
  include HiveTestHelper

  def test_thesis_round_trips_through_state_store
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::StateStore.new(dir)
      store.ensure!
      thesis = sample_thesis

      store.write_thesis(thesis)
      data = JSON.parse(File.read(File.join(store.root, "theses", "#{thesis.id}.json")))
      round_tripped = Hive::RefactorPatrol::Thesis.from_h(data)

      assert_equal thesis.to_h, round_tripped.to_h
    end
  end

  def test_feature_round_trips_through_state_store
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::StateStore.new(dir)
      feature = Hive::Patrol::Feature.new(
        id: "checkout",
        kind: "command",
        entrypoints: [ "bin/hive" ],
        owned_files: [ "lib/checkout.rb" ],
        context_files: [],
        tests: []
      )

      store.write_feature(feature)

      assert_equal feature.to_h, JSON.parse(File.read(File.join(store.root, "features", "checkout.json")))
    end
  end

  def test_read_json_returns_empty_hash_for_unreadable_path
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::StateStore.new(dir)

      assert_equal({}, store.read_json(dir))
    end
  end

  def test_write_json_preserves_existing_file_when_temp_garbage_exists
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::StateStore.new(dir)
      path = File.join(store.root, "state.json")
      store.write_json(path, { "ok" => true })
      File.write("#{path}.tmp.#{Process.pid}.leftover", "{")

      assert_equal({ "ok" => true }, store.read_json(path))
    end
  end

  def test_similar_known_matches_same_feature_wording
    thesis = sample_thesis(problem: "Checkout owns tangled validation and payment orchestration")
    fingerprints = {}
    fp = Hive::RefactorPatrol::Fingerprint.compute(thesis, project_root: Dir.pwd)
    Hive::RefactorPatrol::Fingerprint.record_seen(fingerprints, fp, thesis: thesis)

    similar = sample_thesis(problem: "Checkout has tangled validation plus payment orchestration")
    assert Hive::RefactorPatrol::Fingerprint.similar_known?(fingerprints, {}, similar)

    unrelated = sample_thesis(
      problem: "Invoice rendering duplicates PDF template logic",
      proposed_refactor: "Centralize invoice PDF formatting in one renderer"
    )
    refute Hive::RefactorPatrol::Fingerprint.similar_known?(fingerprints, {}, unrelated)
  end

  def test_dismissed_entry_is_similar_known
    thesis = sample_thesis
    dismissed = {
      "abc" => {
        "state" => "dismissed",
        "feature_id" => thesis.feature_id,
        "title_tokens" => Hive::RefactorPatrol::Fingerprint.title_tokens(thesis)
      }
    }

    assert Hive::RefactorPatrol::Fingerprint.similar_known?({}, dismissed, thesis)
  end

  def test_different_features_do_not_collide_on_similarity_or_exact_fingerprint
    left = sample_thesis(feature_id: "feature-a")
    right = sample_thesis(feature_id: "feature-b")
    left_fp = Hive::RefactorPatrol::Fingerprint.compute(left, project_root: Dir.pwd)
    right_fp = Hive::RefactorPatrol::Fingerprint.compute(right, project_root: Dir.pwd)

    refute_equal left_fp, right_fp
    fingerprints = {}
    Hive::RefactorPatrol::Fingerprint.record_seen(fingerprints, left_fp, thesis: left)
    refute Hive::RefactorPatrol::Fingerprint.similar_known?(fingerprints, {}, right)
  end

  def test_run_dir_is_unique
    with_tmp_dir do |dir|
      store = Hive::RefactorPatrol::StateStore.new(dir)
      a = store.run_dir("review")
      b = store.run_dir("review")

      refute_equal a, b
      assert Dir.exist?(a)
      assert Dir.exist?(b)
    end
  end

  private

  def sample_thesis(overrides = {})
    data = {
      id: "thesis-1",
      feature_id: "checkout",
      feature: "Checkout",
      problem: "Checkout owns tangled validation and payment orchestration",
      cost: "Changes repeatedly fan out across checkout files",
      evidence: [ { "file" => "lib/checkout.rb", "signal" => "churn", "value" => 8 } ],
      proposed_refactor: "Extract payment coordination behind a checkout boundary service",
      feature_boundary: { "owned_files" => [ "lib/checkout.rb" ], "entrypoints" => [ "lib/checkout.rb" ] },
      expected_leverage: { "score" => 0.7, "breakdown" => { "churn" => 0.7 } },
      confidence: "medium",
      risk: {
        "caps" => { "est_files" => 2, "est_diff_lines" => 80, "single_feature" => true },
        "public_api_impact" => false,
        "public_api_details" => [],
        "cross_feature_impact" => false,
        "cross_feature_details" => [],
        "flags" => []
      },
      required_validation: { "commands" => [ "test" ], "characterization_first" => false, "notes" => "Run tests" },
      admissible: true,
      admissibility_reason: "ok",
      follow_up_approval_state: "pending",
      fingerprint: "fp"
    }.merge(overrides)
    Hive::RefactorPatrol::Thesis.new(**data)
  end
end
